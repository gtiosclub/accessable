import CoreGraphics
import Foundation

/// One tracked object as the announcer sees it in a frame.
struct ObstacleAlertInput: Sendable {
    /// Must carry a `distance`; anything without one is ignored.
    let detection: Detection
    /// Whether the object is inside the walking corridor this frame.
    let isInPath: Bool
}

/// What the occupancy map says about the corridor straight ahead. Passing one makes the
/// map, not this frame's detections, decide whether the path is blocked; detections then
/// only supply the name of what blocks it.
struct BlockedAhead: Sendable, Equatable {
    /// Distance to the first occupied cell; nil when the corridor is free for the whole
    /// look-ahead.
    var distance: Float?
}

/// Decides what the user hears about their path, and when. Owner: Computer Vision (1.1 / task T16).
///
/// The subject is the path, not each object. Whatever is nearest in the walking corridor
/// sets the state — clear, or blocked at one of three distance bands — and the user hears
/// about the state, not about every detection: once when something first blocks the path,
/// again each time it comes a band nearer, and once more when the path is clear again. The
/// band carries the advice from `PathAssessment` ("Go left"), and a change of advice is
/// news too, with a cooldown so it cannot flap.
///
/// What keeps it quiet:
/// - A band must hold for `confirmationFrames` frames before it counts, so one frame of
///   depth speckle says nothing.
/// - Leaving a band outward needs `hysteresis` metres beyond its threshold, so an object
///   sitting on a threshold does not toggle.
/// - Nothing is spoken within `minimumInterval` of the last announcement unless it is more
///   urgent than that announcement was.
/// - Track identity is never relied on. Geometric obstacles get a fresh ID whenever their
///   cluster splits or their box jumps, and keying on IDs made every jump a new object.
///
/// Kerbs, steps and drop-offs follow the same band rules, one state per hazard type, and a
/// repeat is held back for `hazardRepeatInterval` because kerb detection flickers.
///
/// Output goes to the shared `AnnouncementSink`; the announcement engine (3.3) decides how
/// and whether to speak it, given the user's profile.
struct ObstacleAnnouncer: Sendable {
    /// Distance bands in metres, farthest first; the last is "stop". Two by default: a
    /// warning with the way round at 2.5 m, and "Stop" at 1.2 m. A third, farther band
    /// (e.g. `[3, 2, 1]`) adds an information-only notice with the distance.
    var thresholds: [Float] = [2.5, 1.2]
    /// How far beyond a band's threshold an object must move before it leaves the band.
    var hysteresis: Float = 0.35
    /// Consecutive analyzed frames a new band must hold before it is believed.
    var confirmationFrames = 2
    /// The same for kerbs and steps, which flicker more than objects do.
    var hazardConfirmationFrames = 3
    /// How long the corridor must stay empty before the path counts as clear.
    var clearAfter: TimeInterval = 1.0
    /// Minimum gap between two announcements, unless the second is more urgent.
    var minimumInterval: TimeInterval = 2.5
    /// After the path clears, the same band is not announced again for this long. A
    /// detection flickering at the corridor edge would otherwise alternate with "Path clear".
    var rearmInterval: TimeInterval = 4.0
    /// A new direction must hold for this long before it counts as a change of advice.
    var adviceStableFor: TimeInterval = 1.0
    /// A change of advice ("Go left" → "Go right") is spoken at most this often.
    var adviceChangeInterval: TimeInterval = 4.0
    /// While still in the nearest band, the warning is repeated this often.
    var repeatInterval: TimeInterval = 8.0
    /// A detection this close to the map's blocked distance is what is blocking the path,
    /// and lends its name.
    var subjectTolerance: Float = 0.8
    /// A kerb or step at a band already spoken is not repeated for this long.
    var hazardRepeatInterval: TimeInterval = 8.0
    /// Surface hazards worth speaking. `.unknown` is a hole in depth coverage, which dark
    /// or glossy floors produce constantly; it stays in the observation for the UI only.
    var announcedHazardTypes: Set<ElevationHazardType> = [.stepUp, .stepDown, .dropOff]
    /// An announcement not delivered within this long is stale; the engine may drop it.
    var announcementLifetime: TimeInterval = 1.5

    /// Band state for one subject: the path, or one type of surface hazard.
    private struct BandState {
        /// The confirmed band, nil when nothing is within the outermost threshold.
        var band: Int?
        var candidate: Int?
        var candidateFrames = 0
        var lastPresent: TimeInterval = -.infinity
        /// The band last spoken in this episode; nil once the subject has cleared.
        var announcedBand: Int?
        var announcedDirection: ClearDirection?
        /// Whether this episode included a warning at 2 m or nearer, which earns "Path clear".
        var warned = false
        /// The last band ever spoken and when, across episodes, for re-arming.
        var lastSpokenBand: Int?
        var lastSpoken: TimeInterval = -.infinity

        mutating func observe(distance: Float?, at time: TimeInterval, rules: ObstacleAnnouncer, confirmationFrames: Int) {
            guard let distance else {
                // An absent frame breaks a run of consecutive sightings.
                candidate = nil
                candidateFrames = 0
                if time - lastPresent > rules.clearAfter { band = nil }
                return
            }
            lastPresent = time

            var observed = rules.thresholds.lastIndex(where: { distance <= $0 })
            if let current = band, (observed ?? -1) < current,
               distance <= rules.thresholds[current] + rules.hysteresis {
                observed = current
            }
            if observed == band {
                candidate = nil
                candidateFrames = 0
                return
            }
            if observed == candidate {
                candidateFrames += 1
            } else {
                candidate = observed
                candidateFrames = 1
            }
            if candidateFrames >= confirmationFrames {
                band = observed
                candidate = nil
                candidateFrames = 0
            }
        }

        mutating func spoke(band: Int, direction: ClearDirection?, isStop: Bool, at time: TimeInterval) {
            announcedBand = band
            announcedDirection = direction
            lastSpokenBand = band
            lastSpoken = time
            if isStop { warned = true }
        }

        mutating func clearEpisode() {
            announcedBand = nil
            announcedDirection = nil
            warned = false
        }
    }

    private var path = BandState()
    /// The nearest in-path detection most recently seen; what the announcement describes.
    private var subject: Detection?
    /// Advice is debounced: a direction has to hold for `adviceStableFor` to replace the
    /// current one, so the map's momentary opinions never reach the user.
    private var stableDirection: ClearDirection?
    private var pendingDirection: ClearDirection?
    private var pendingSince: TimeInterval = -.infinity
    private var hazards: [ElevationHazardType: BandState] = [:]
    private var lastAnnouncement: TimeInterval = -.infinity
    private var lastPriority: AnnouncementPriority?

    init() {}

    /// Updates the state with one frame and returns what should be announced, most urgent first.
    ///
    /// - Parameters:
    ///   - objects: Every detection this frame with its in-path flag.
    ///   - hazards: Kerbs, steps and drop-offs this frame.
    ///   - path: Where the open space is, when the geometry could tell.
    ///   - blockedAhead: The map's view of the corridor. When given, it decides the band.
    ///   - time: The frame's capture time in seconds (`ARFrame.timestamp`).
    ///   - now: Wall-clock time, used for the events' `createdAt` and `expiresAt`.
    mutating func announcements(
        for objects: [ObstacleAlertInput],
        hazards: [ElevationHazard],
        path assessment: PathAssessment? = nil,
        blockedAhead: BlockedAhead? = nil,
        at time: TimeInterval,
        now: Date = .now
    ) -> [AnnouncementEvent] {
        var events: [AnnouncementEvent] = []
        if let event = pathAnnouncement(for: objects, path: assessment, blockedAhead: blockedAhead, at: time, now: now) {
            events.append(event)
        }
        events += hazardAnnouncements(for: hazards, at: time, now: now)
        return events.sorted { $0.priority > $1.priority }
    }

    // MARK: - The path

    private mutating func pathAnnouncement(
        for objects: [ObstacleAlertInput],
        path assessment: PathAssessment?,
        blockedAhead: BlockedAhead?,
        at time: TimeInterval,
        now: Date
    ) -> AnnouncementEvent? {
        let inPath = objects
            .filter { $0.isInPath && $0.detection.distance != nil }
            .sorted { $0.detection.distance! < $1.detection.distance! }

        // The map decides whether the path is blocked; detections say what by.
        let distance: Float? = if let blockedAhead {
            blockedAhead.distance
        } else {
            inPath.first.flatMap { $0.detection.distance.map(Float.init) }
        }
        if let distance {
            if let match = inPath.first(where: { abs(Float($0.detection.distance!) - distance) <= subjectTolerance }) {
                subject = match.detection
            } else if blockedAhead != nil {
                subject = Detection(
                    label: Detection.obstacleLabel, confidence: 1, boundingBox: .zero,
                    distance: Double(distance), bearing: .ahead, origin: .geometric, isHazard: true
                )
            }
        }
        path.observe(distance: distance, at: time, rules: self, confirmationFrames: confirmationFrames)
        let direction = debouncedDirection(assessment?.clearDirection, at: time)

        guard let band = path.band else {
            // The corridor is clear. Say so once if the user was warned, then start over.
            guard path.announcedBand != nil else { return nil }
            guard path.warned else {
                path.clearEpisode()
                return nil
            }
            guard admit(.normal, at: time) else { return nil }
            path.clearEpisode()
            return AnnouncementEvent(
                category: .hazard,
                priority: .normal,
                text: SpokenPhrasing.pathClear,
                bearing: .ahead,
                source: .obstacleDetection,
                createdAt: now,
                expiresAt: now.addingTimeInterval(announcementLifetime),
                dedupKey: "path-clear"
            )
        }

        let adviceBand = max(thresholds.count - 2, 0)
        let shouldSpeak: Bool
        if let announced = path.announcedBand {
            if band > announced {
                shouldSpeak = true
            } else if band == announced {
                let adviceChanged = band >= adviceBand && direction != nil && direction != path.announcedDirection
                    && time - path.lastSpoken >= adviceChangeInterval
                let reminderDue = band == thresholds.count - 1 && time - path.lastSpoken >= repeatInterval
                shouldSpeak = adviceChanged || reminderDue
            } else {
                // Receding: nothing to say, but coming back in is news again.
                path.announcedBand = band
                shouldSpeak = false
            }
        } else {
            // A new episode. Re-announcing the band just spoken, right after clearing, is
            // the corridor-edge flicker this is meant to silence.
            let rearmed = path.lastSpokenBand.map { band > $0 || time - path.lastSpoken >= rearmInterval } ?? true
            shouldSpeak = rearmed
        }
        guard shouldSpeak, let subject else { return nil }

        let (priority, haptic) = urgency(ofBand: band)
        guard admit(priority, at: time) else { return nil }
        path.spoke(band: band, direction: direction, isStop: band == thresholds.count - 1, at: time)
        // Phrase the debounced direction, with the current assessment's detail when they agree.
        let spokenPath: PathAssessment? = if let direction {
            assessment?.clearDirection == direction ? assessment : PathAssessment(clearDirection: direction, sidestep: nil)
        } else {
            nil
        }
        return AnnouncementEvent(
            category: .hazard,
            priority: priority,
            text: SpokenPhrasing.guidance(for: subject, priority: priority, path: spokenPath),
            haptic: haptic,
            bearing: subject.bearing,
            source: .obstacleDetection,
            createdAt: now,
            expiresAt: now.addingTimeInterval(announcementLifetime),
            dedupKey: "path-\(subject.label)-\(band)-\(direction?.rawValue ?? "none")"
        )
    }

    // MARK: - Surface hazards

    private mutating func hazardAnnouncements(
        for hazards: [ElevationHazard],
        at time: TimeInterval,
        now: Date
    ) -> [AnnouncementEvent] {
        // The ground profile is sampled inside the corridor, so a hazard is always in the
        // path. Only the nearest of each type matters.
        var nearest: [ElevationHazardType: ElevationHazard] = [:]
        for hazard in hazards where announcedHazardTypes.contains(hazard.type) {
            if hazard.distance < (nearest[hazard.type]?.distance ?? .infinity) {
                nearest[hazard.type] = hazard
            }
        }

        var events: [AnnouncementEvent] = []
        // Present hazards nearest first, then the absent ones so their state can clear.
        let order = announcedHazardTypes.sorted {
            (nearest[$0]?.distance ?? .infinity, $0.rawValue) < (nearest[$1]?.distance ?? .infinity, $1.rawValue)
        }
        for type in order {
            var state = self.hazards[type] ?? BandState()
            defer { self.hazards[type] = state }
            let hazard = nearest[type]
            state.observe(distance: hazard?.distance, at: time, rules: self, confirmationFrames: hazardConfirmationFrames)

            guard let band = state.band else {
                state.clearEpisode()
                continue
            }
            // Still within a band but not seen this frame: a flicker, nothing to decide.
            guard let hazard else { continue }
            if let announced = state.announcedBand {
                guard band > announced else {
                    if band < announced { state.announcedBand = band }
                    continue
                }
            }
            let rearmed = state.lastSpokenBand.map { band > $0 || time - state.lastSpoken >= hazardRepeatInterval } ?? true
            guard rearmed else { continue }

            let (priority, haptic) = urgency(of: hazard.type, band: band)
            guard admit(priority, at: time) else { continue }
            state.spoke(band: band, direction: nil, isStop: priority == .critical, at: time)
            events.append(AnnouncementEvent(
                category: .hazard,
                priority: priority,
                text: SpokenPhrasing.guidance(for: hazard, priority: priority),
                haptic: haptic,
                bearing: .ahead,
                source: .obstacleDetection,
                createdAt: now,
                expiresAt: now.addingTimeInterval(announcementLifetime),
                dedupKey: "surface-\(hazard.type.rawValue)-\(band)"
            ))
        }
        return events
    }

    /// The direction to act on: the current one until a different one has held for
    /// `adviceStableFor`. The very first direction is taken at once.
    private mutating func debouncedDirection(_ observed: ClearDirection?, at time: TimeInterval) -> ClearDirection? {
        guard let observed else { return stableDirection }
        if stableDirection == nil {
            stableDirection = observed
            return observed
        }
        if observed == stableDirection {
            pendingDirection = nil
        } else if observed == pendingDirection {
            if time - pendingSince >= adviceStableFor {
                stableDirection = observed
                pendingDirection = nil
            }
        } else {
            pendingDirection = observed
            pendingSince = time
        }
        return stableDirection
    }

    // MARK: - Shared rules

    /// The global gate: one announcement per `minimumInterval`, except escalations.
    private mutating func admit(_ priority: AnnouncementPriority, at time: TimeInterval) -> Bool {
        if time - lastAnnouncement < minimumInterval, let last = lastPriority, priority <= last {
            return false
        }
        lastAnnouncement = time
        lastPriority = priority
        return true
    }

    private func urgency(ofBand band: Int) -> (priority: AnnouncementPriority, haptic: HapticID) {
        switch thresholds.count - 1 - band {
        case 0: (.critical, .stop)
        case 1: (.high, .obstacleNearer)
        default: (.normal, .obstacleNear)
        }
    }

    /// A drop-off is a fall risk at any distance and gets "Stop" up close; a kerb or step
    /// is something to be ready for, so it tops out at high priority.
    private func urgency(of type: ElevationHazardType, band: Int) -> (priority: AnnouncementPriority, haptic: HapticID) {
        let (priority, haptic) = urgency(ofBand: band)
        switch type {
        case .dropOff:
            return priority < .high ? (.high, .obstacleNearer) : (priority, haptic)
        default:
            return priority == .critical ? (.high, .attention) : (priority, haptic)
        }
    }
}
