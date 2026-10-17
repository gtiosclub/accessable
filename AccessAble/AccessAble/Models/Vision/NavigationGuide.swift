import Foundation
import simd

// Steering the user to something they asked for (1.2, "take me to the chair").
//
// The target is found by looking around: everything the pipeline recognizes (T13, T14)
// and reads (T17) carries a world position, and ARKit's world does not move while
// tracking runs. So a slow turn on the spot is a scan of the room, a sighting is a
// coordinate, and from then on the guide only needs the camera pose to say which way to
// turn and how far is left. Obstacle warnings keep running underneath; they are more
// urgent than any of this.

/// What the guide is doing right now, for the screen and for VoiceOver.
struct NavigationStatus: Equatable, Sendable {
    enum Phase: String, Sendable {
        /// Turning on the spot, looking for the target.
        case scanning
        /// The target has a position; steering towards it.
        case guiding
        /// Within arm's reach of the target.
        case arrived
        /// A full turn did not show the target.
        case notFound
    }

    /// What the user asked for, as they said it.
    var query: String
    var phase: Phase
    /// How much of a full turn has been scanned, in degrees.
    var scannedDegrees: Float = 0
    /// Horizontal distance to the target in metres, once it has a position.
    var distance: Float?
    var bearing: RelativeBearing?

    /// One line for the readout: "Looking for a chair — turn slowly (120°)".
    var description: String {
        switch phase {
        case .scanning: "Looking for \(query) — turn slowly (\(Int(scannedDegrees))°)"
        case .guiding:
            if let distance, let bearing {
                "\(query.prefix(1).uppercased() + query.dropFirst()): \(SpokenPhrasing.shortDistance(Double(distance))), \(SpokenPhrasing.direction(bearing))"
            } else {
                "Guiding to \(query)"
            }
        case .arrived: "Arrived at \(query)"
        case .notFound: "Could not find \(query)"
        }
    }
}

/// Knobs for `NavigationGuide`.
struct NavigationTuning: Sendable {
    /// Horizontal distance at which the target counts as reached.
    var arrivalDistance: Float = 1.0
    /// A scan that has turned this far without a sighting gives up.
    var scanDegrees: Float = 340
    /// A scan that has lasted this long without a sighting gives up, in seconds.
    var scanTimeout: TimeInterval = 30
    /// Unchanged instructions are repeated this often, in seconds.
    var repeatInterval: TimeInterval = 4
    /// A changed instruction waits at least this long after the previous one.
    var changeInterval: TimeInterval = 1.5
    /// Sightings kept for the position estimate; the median of these is the target.
    var sightingsKept = 5
    /// An announcement not delivered within this long is stale.
    var announcementLifetime: TimeInterval = 2

    static let `default` = NavigationTuning()

    init() {}
}

/// Finds and steers towards one target. Create one per request; feed it every frame.
struct NavigationGuide: Sendable {
    let query: String
    var tuning: NavigationTuning

    private let terms: Set<String>
    private let startTime: TimeInterval
    private var sightings: [SIMD3<Float>] = []
    private var scannedDegrees: Float = 0
    private var lastHeadingAngle: Float?
    private(set) var phase: NavigationStatus.Phase = .scanning
    private var lastInstruction: String?
    private var lastSpoken: TimeInterval = -.infinity
    private var saidIntro = false

    /// - Parameters:
    ///   - query: What the user asked for, e.g. "the chair", "exit", "room 210".
    ///   - time: The current frame time (`ARFrame.timestamp`).
    init(query: String, at time: TimeInterval, tuning: NavigationTuning = .default) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tuning = tuning
        terms = Self.terms(for: self.query)
        startTime = time
    }

    /// Whether the guide is still working; false once arrived or given up.
    var isActive: Bool { phase == .scanning || phase == .guiding }

    /// Where the target is believed to be: the component-wise median of recent sightings.
    var estimatedPosition: SIMD3<Float>? {
        guard !sightings.isEmpty else { return nil }
        return SIMD3(
            median(sightings.map(\.x)),
            median(sightings.map(\.y)),
            median(sightings.map(\.z))
        )
    }

    /// Feeds one frame.
    ///
    /// - Parameters:
    ///   - detections: This frame's detections; those matching the query with a world
    ///     position are sightings.
    ///   - text: Text currently in view, likewise.
    ///   - heading: The user's level heading: origin at the camera, `forward` along the
    ///     ground, `right` level.
    ///   - time: The frame's capture time.
    ///   - now: Wall-clock time for the event.
    /// - Returns: The status, and an instruction to speak if one is due.
    mutating func update(
        detections: [Detection],
        text: [RecognizedText],
        heading: WalkingCorridor,
        at time: TimeInterval,
        now: Date = .now
    ) -> (status: NavigationStatus, announcement: AnnouncementEvent?) {
        guard isActive else { return (status(heading: heading), nil) }

        // Scan progress: how far the heading has swung since the start.
        let angle = atan2(heading.forward.x, -heading.forward.z)
        if let last = lastHeadingAngle {
            var delta = angle - last
            if delta > .pi { delta -= 2 * .pi }
            if delta < -.pi { delta += 2 * .pi }
            scannedDegrees += abs(delta) * 180 / .pi
        }
        lastHeadingAngle = angle

        // Sightings.
        let positions = detections.filter { matches($0.label) }.compactMap(\.worldPosition)
            + text.filter { matchesText($0.string) }.compactMap(\.worldPosition)
        for position in positions where position.x.isFinite && position.y.isFinite && position.z.isFinite {
            sightings.append(position)
        }
        if sightings.count > tuning.sightingsKept {
            sightings.removeFirst(sightings.count - tuning.sightingsKept)
        }

        guard let target = estimatedPosition else {
            if scannedDegrees >= tuning.scanDegrees || time - startTime >= tuning.scanTimeout {
                phase = .notFound
                return (status(heading: heading), event("I couldn't find \(query) here.", priority: .normal, haptic: .error, now: now))
            }
            if !saidIntro {
                saidIntro = true
                lastSpoken = time
                return (status(heading: heading), event("Looking for \(query). Turn slowly all the way around.", priority: .normal, haptic: .attention, now: now))
            }
            return (status(heading: heading), nil)
        }

        phase = .guiding
        let distance = horizontalDistance(to: target, heading: heading)
        let bearing = heading.bearing(to: target)

        if distance <= tuning.arrivalDistance {
            phase = .arrived
            return (
                status(heading: heading),
                event("You have arrived. \(capitalized(query)) is right in front of you.", priority: .high, haptic: .arrived, bearing: bearing, now: now)
            )
        }

        let (instruction, haptic) = Self.instruction(for: query, distance: distance, bearing: bearing)
        let changed = instruction != lastInstruction
        let due = changed ? time - lastSpoken >= tuning.changeInterval : time - lastSpoken >= tuning.repeatInterval
        guard due else { return (status(heading: heading), nil) }
        lastInstruction = instruction
        lastSpoken = time
        return (status(heading: heading), event(instruction, priority: .normal, haptic: haptic, bearing: bearing, now: now))
    }

    // MARK: - Matching

    /// Words the query might appear as in a label: the query itself, minus filler, plus
    /// common synonyms for the model's vocabulary.
    private static func terms(for query: String) -> Set<String> {
        let filler: Set<String> = ["the", "a", "an", "to", "my", "nearest", "closest", "me", "take", "go", "navigate", "find", "please"]
        let words = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !filler.contains($0) }
        var terms = Set(words)
        if !words.isEmpty { terms.insert(words.joined(separator: " ")) }
        for word in words {
            for synonym in synonyms[word] ?? [] { terms.insert(synonym) }
            if word.hasSuffix("s") { terms.insert(String(word.dropLast())) }
        }
        return terms
    }

    /// Everyday words for what the detector calls things.
    static let synonyms: [String: [String]] = [
        "people": ["person"], "someone": ["person"], "somebody": ["person"], "man": ["person"],
        "woman": ["person"], "human": ["person"], "friend": ["person"],
        "seat": ["chair", "bench", "couch"], "sofa": ["couch"], "settee": ["couch"],
        "table": ["dining table"], "desk": ["dining table"],
        "bike": ["bicycle"], "plant": ["potted plant"], "screen": ["tv"], "monitor": ["tv"],
        "television": ["tv"], "computer": ["laptop"], "bag": ["suitcase", "backpack", "handbag"],
        "luggage": ["suitcase"], "hydrant": ["fire hydrant"], "loo": ["toilet"], "bathroom": ["toilet"],
        "restroom": ["toilet"], "fridge": ["refrigerator"], "phone": ["cell phone"], "mobile": ["cell phone"],
        "exit": ["exit", "way out"], "way out": ["exit"],
    ]

    func matches(_ label: String) -> Bool {
        let label = label.lowercased()
        return terms.contains(label) || terms.contains { $0.count >= 3 && (label.contains($0) || $0.contains(label)) }
    }

    func matchesText(_ string: String) -> Bool {
        let text = string.lowercased()
        return terms.contains { $0.count >= 3 && text.contains($0) }
    }

    // MARK: - Phrasing

    /// "Chair straight ahead, 3 metres." / "Turn left. Chair is 3 metres away."
    static func instruction(for query: String, distance: Float, bearing: RelativeBearing) -> (String, HapticID) {
        let name = capitalized(query)
        let metres = SpokenPhrasing.shortDistance(Double(distance))
        switch bearing.side {
        case .ahead: return ("\(name) straight ahead, \(metres).", .onRouteHeartbeat)
        case .slightlyLeft: return ("\(name) slightly left, \(metres).", .turnLeft)
        case .slightlyRight: return ("\(name) slightly right, \(metres).", .turnRight)
        case .left: return ("Turn left. \(name) is \(metres) away.", .turnLeft)
        case .right: return ("Turn right. \(name) is \(metres) away.", .turnRight)
        case .behind: return ("Turn around. \(name) is behind you, \(metres).", bearing.degrees < 0 ? .turnLeft : .turnRight)
        }
    }

    private func status(heading: WalkingCorridor) -> NavigationStatus {
        var status = NavigationStatus(query: query, phase: phase, scannedDegrees: min(scannedDegrees, 360))
        if let target = estimatedPosition {
            status.distance = horizontalDistance(to: target, heading: heading)
            status.bearing = heading.bearing(to: target)
        }
        return status
    }

    private func horizontalDistance(to target: SIMD3<Float>, heading: WalkingCorridor) -> Float {
        let offset = target - heading.origin
        let along = simd_dot(offset, heading.forward)
        let lateral = simd_dot(offset, heading.right)
        return (along * along + lateral * lateral).squareRoot()
    }

    private func event(_ text: String, priority: AnnouncementPriority, haptic: HapticID, bearing: RelativeBearing? = nil, now: Date) -> AnnouncementEvent {
        AnnouncementEvent(
            category: .maneuver,
            priority: priority,
            text: text,
            haptic: haptic,
            bearing: bearing,
            source: .navigation,
            createdAt: now,
            expiresAt: now.addingTimeInterval(tuning.announcementLifetime),
            dedupKey: "navigate-\(text)"
        )
    }
}

private func capitalized(_ query: String) -> String {
    query.prefix(1).uppercased() + query.dropFirst()
}
