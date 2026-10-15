import Foundation

/// One tracked object as the announcer sees it in a frame.
struct ObstacleAlertInput: Sendable {
    /// Must carry a `trackID` and a `distance`; anything without both is ignored.
    let detection: Detection
    /// Whether the object is inside the walking corridor this frame.
    let isInPath: Bool
}

/// Decides which obstacles deserve an announcement, so the user hears each one once per
/// distance band rather than every frame. Owner: Computer Vision (1.1 / task T16).
///
/// An object in the walking corridor is announced when it first comes within the outermost
/// threshold, and again each time it crosses a nearer one; each band is more urgent than
/// the last. Moving back out to a farther band does not repeat an announcement. An object
/// must be out of the corridor for `exitGracePeriod` before it counts as having left, so a
/// detection flickering at the corridor's edge is not re-announced on every flicker.
/// Kerbs, steps and drop-offs follow the same rules, keyed by their type.
///
/// Output goes to the shared `AnnouncementSink`; the announcement engine (3.3) decides how
/// and whether to speak it, given the user's profile.
struct ObstacleAnnouncer: Sendable {
    /// Distance bands in metres, farthest first. The first is the "new obstacle" announcement.
    var thresholds: [Float] = [3, 2, 1]
    /// How long an object must stay out of the corridor before re-entering it is news again.
    var exitGracePeriod: TimeInterval = 1.0
    /// State for objects not seen for this long is discarded.
    var forgetAfter: TimeInterval = 3.0
    /// An announcement not delivered within this long is stale; the engine may drop it.
    var announcementLifetime: TimeInterval = 1.5

    private enum Subject: Hashable {
        case object(UUID)
        case surface(ElevationHazardType)
    }

    private struct SubjectState {
        /// Index into `thresholds` of the nearest band already announced.
        var announcedBand: Int?
        var lastInPath: TimeInterval
        var lastSeen: TimeInterval
    }

    private var states: [Subject: SubjectState] = [:]

    init() {}

    /// Updates the state with one frame and returns what should be announced, most urgent first.
    ///
    /// - Parameters:
    ///   - time: The frame's capture time in seconds (`ARFrame.timestamp`).
    ///   - now: Wall-clock time, used for the events' `createdAt` and `expiresAt`.
    mutating func announcements(
        for objects: [ObstacleAlertInput],
        hazards: [ElevationHazard],
        at time: TimeInterval,
        now: Date = .now
    ) -> [AnnouncementEvent] {
        var events: [AnnouncementEvent] = []

        for object in objects {
            guard let id = object.detection.trackID, let distance = object.detection.distance else { continue }
            let band = observe(.object(id), distance: Float(distance), isInPath: object.isInPath, at: time)
            if let band {
                events.append(event(for: object.detection, band: band, now: now))
            }
        }

        // The ground profile is sampled inside the corridor, so a hazard is always in the path.
        // Only the nearest hazard of each type matters.
        var nearest: [ElevationHazardType: ElevationHazard] = [:]
        for hazard in hazards where hazard.distance < (nearest[hazard.type]?.distance ?? .infinity) {
            nearest[hazard.type] = hazard
        }
        for hazard in nearest.values.sorted(by: { $0.distance < $1.distance }) {
            if let band = observe(.surface(hazard.type), distance: hazard.distance, isInPath: true, at: time) {
                events.append(event(for: hazard, band: band, now: now))
            }
        }

        states = states.filter { time - $0.value.lastSeen <= forgetAfter }
        return events.sorted { $0.priority > $1.priority }
    }

    /// Records a sighting and returns the band to announce, if this sighting crossed into a
    /// nearer one.
    private mutating func observe(_ subject: Subject, distance: Float, isInPath: Bool, at time: TimeInterval) -> Int? {
        var state = states[subject] ?? SubjectState(announcedBand: nil, lastInPath: -.infinity, lastSeen: time)
        state.lastSeen = time
        defer { states[subject] = state }

        guard isInPath else {
            if time - state.lastInPath > exitGracePeriod { state.announcedBand = nil }
            return nil
        }
        state.lastInPath = time

        guard let band = thresholds.lastIndex(where: { distance <= $0 }) else { return nil }
        if let announced = state.announcedBand, band <= announced { return nil }
        state.announcedBand = band
        return band
    }

    private func urgency(ofBand band: Int) -> (priority: AnnouncementPriority, haptic: HapticID) {
        switch thresholds.count - 1 - band {
        case 0: (.critical, .stop)
        case 1: (.high, .obstacleNearer)
        default: (.normal, .obstacleNear)
        }
    }

    private func event(for detection: Detection, band: Int, now: Date) -> AnnouncementEvent {
        let (priority, haptic) = urgency(ofBand: band)
        let text = SpokenPhrasing.describe(detection)
        return AnnouncementEvent(
            category: .hazard,
            priority: priority,
            text: priority == .critical ? "Stop. " + text : text,
            haptic: haptic,
            bearing: detection.bearing,
            source: .obstacleDetection,
            createdAt: now,
            expiresAt: now.addingTimeInterval(announcementLifetime),
            dedupKey: "obstacle-\(detection.trackID?.uuidString ?? "")-\(band)"
        )
    }

    private func event(for hazard: ElevationHazard, band: Int, now: Date) -> AnnouncementEvent {
        var (priority, haptic) = urgency(ofBand: band)
        // A drop-off is a fall risk at any distance we report it.
        if hazard.type == .dropOff, priority < .high {
            (priority, haptic) = (.high, .obstacleNearer)
        }
        let text = SpokenPhrasing.describe(hazard)
        return AnnouncementEvent(
            category: .hazard,
            priority: priority,
            text: priority == .critical ? "Stop. " + text : text,
            haptic: haptic,
            bearing: .ahead,
            source: .obstacleDetection,
            createdAt: now,
            expiresAt: now.addingTimeInterval(announcementLifetime),
            dedupKey: "surface-\(hazard.type.rawValue)-\(band)"
        )
    }
}
