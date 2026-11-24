import Foundation

/// Decides what the user hears about things moving toward them. Owner: Computer Vision (1.1 / task T34).
///
/// Separate from `ObstacleAnnouncer` (T16) because the subject is different. T16 describes
/// the state of the path at distance bands; this describes one moving object and how long
/// there is to react, so urgency comes from time rather than distance. A car four metres
/// away is nothing if it is parked and everything if it arrives in a second.
///
/// What keeps it quiet:
/// - One state per track, so a warning fires when something starts approaching rather than
///   every frame it keeps approaching.
/// - A warning is repeated only when it becomes more urgent, or after `repeatInterval`.
/// - Nothing is spoken within `minimumInterval` of this announcer's last warning unless it
///   is more urgent, the same rule T16 uses on itself.
/// - A track that stops qualifying is forgotten after `clearAfter`, so an object that
///   flickers in and out of the speed threshold does not re-announce each time.
///
/// Output goes to the shared `AnnouncementSink`; the announcement engine (3.3) decides how
/// and whether to speak it, given the user's profile.
struct ApproachAnnouncer: Sendable {
    /// Time-to-approach thresholds in seconds, most urgent first. Inside 1.5 s there is only
    /// time to stop; inside 3 s there is time to stop or step aside; beyond that it is
    /// information.
    var urgentWithin: Float = 1.5
    var warningWithin: Float = 3
    /// Consecutive frames an approach must hold before it is believed. A velocity fitted to
    /// a handful of noisy positions can produce one bad frame.
    var confirmationFrames = 2
    /// How long a track must stop qualifying before its state is cleared.
    var clearAfter: TimeInterval = 1.0
    /// Minimum gap between two approach warnings, unless the second is more urgent.
    var minimumInterval: TimeInterval = 2.0
    /// While an object is still approaching, its warning is repeated this often.
    var repeatInterval: TimeInterval = 4.0
    /// An announcement not delivered within this long is stale; approaches go out of date
    /// quickly, so this is shorter than T16's.
    var announcementLifetime: TimeInterval = 1.0
    /// Kinds of thing warned about only once they are urgent. Indoors people walk toward
    /// you all the time, and "Person approaching" for each of them is noise.
    var urgentOnlyLabels: Set<String> = ["person"]
    /// What the user asked to hear about. An urgent approach gets through regardless.
    var alertFilter: AlertFilter?

    private struct TrackState {
        var level: Int?
        var candidate: Int?
        var candidateFrames = 0
        var lastSeen: TimeInterval = -.infinity
        var announcedLevel: Int?
        var lastSpoken: TimeInterval = -.infinity
    }

    private var states: [UUID: TrackState] = [:]
    private var lastAnnouncement: TimeInterval = -.infinity
    private var lastPriority: AnnouncementPriority?

    init() {}

    /// Updates the state with one frame's threats and returns what should be announced,
    /// most urgent first.
    ///
    /// - Parameters:
    ///   - threats: This frame's approaches, from `approachThreats`.
    ///   - time: The frame's capture time in seconds (`ARFrame.timestamp`).
    ///   - now: Wall-clock time, for the events' `createdAt` and `expiresAt`.
    mutating func announcements(
        for threats: [ApproachThreat],
        at time: TimeInterval,
        now: Date = .now
    ) -> [AnnouncementEvent] {
        var events: [AnnouncementEvent] = []

        for threat in threats {
            let level = urgencyLevel(forTimeToApproach: threat.timeToApproach)
            if level < 2 {
                if urgentOnlyLabels.contains(threat.label.lowercased()) { continue }
                if let alertFilter, !alertFilter.allows(DangerLevel(approaching: threat.label)) { continue }
            }

            var state = states[threat.trackID] ?? TrackState()
            defer { states[threat.trackID] = state }
            state.lastSeen = time

            if level == state.candidate {
                state.candidateFrames += 1
            } else if level != state.level {
                state.candidate = level
                state.candidateFrames = 1
            }
            // Becoming urgent is never made to wait for confirmation, whether there was no
            // level before or a calmer one: a frame of delay here is a frame of the only
            // warning that still leaves time to stop.
            let tooUrgentToWait = level == 2 && (state.level ?? 0) < 2
            if state.candidateFrames >= confirmationFrames || tooUrgentToWait {
                state.level = level
                state.candidate = nil
                state.candidateFrames = 0
            }
            guard let confirmed = state.level else { continue }

            let escalated = state.announcedLevel.map { confirmed > $0 } ?? true
            let repeatDue = time - state.lastSpoken >= repeatInterval
            guard escalated || repeatDue else { continue }

            let (priority, haptic) = urgency(ofLevel: confirmed)
            guard admit(priority, at: time) else { continue }
            state.announcedLevel = confirmed
            state.lastSpoken = time
            events.append(AnnouncementEvent(
                category: .hazard,
                priority: priority,
                text: SpokenPhrasing.guidance(for: threat, priority: priority),
                haptic: haptic,
                distance: Double(threat.distance),
                bearing: threat.bearing,
                source: .obstacleDetection,
                topic: .trafficAndCrowds,
                createdAt: now,
                expiresAt: now.addingTimeInterval(announcementLifetime),
                dedupKey: "approach-\(threat.label)-\(confirmed)"
            ))
        }

        // Forget tracks that have stopped approaching, so coming back is news again.
        states = states.filter { time - $0.value.lastSeen <= clearAfter }
        return events.sorted { $0.priority > $1.priority }
    }

    /// 2 inside `urgentWithin`, 1 inside `warningWithin`, 0 beyond.
    private func urgencyLevel(forTimeToApproach seconds: Float) -> Int {
        if seconds <= urgentWithin { return 2 }
        if seconds <= warningWithin { return 1 }
        return 0
    }

    private func urgency(ofLevel level: Int) -> (priority: AnnouncementPriority, haptic: HapticID) {
        switch level {
        case 2: (.critical, .stop)
        case 1: (.high, .attention)
        default: (.normal, .attention)
        }
    }

    /// One warning per `minimumInterval`, except escalations.
    private mutating func admit(_ priority: AnnouncementPriority, at time: TimeInterval) -> Bool {
        if time - lastAnnouncement < minimumInterval, let last = lastPriority, priority <= last {
            return false
        }
        lastAnnouncement = time
        lastPriority = priority
        return true
    }
}
