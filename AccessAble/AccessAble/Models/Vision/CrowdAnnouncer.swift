import Foundation

/// Mentions a crowd in the way, occasionally. Owner: Computer Vision (1.1 / task T35).
///
/// A crowd is context rather than a hazard: anyone in the path is already announced by T16,
/// and this must never stand in for that. So it speaks at `.ambient`, which the user's
/// `GuidanceProfile` can switch off entirely without losing a safety warning.
///
/// What keeps it quiet, which for an ambient announcement is the whole design:
/// - Only a crowd roughly ahead and within `maximumDistance` is ever mentioned. A group off
///   to one side is something to walk past, not something to say.
/// - It speaks once when a crowd first appears, then at most every `minimumInterval`, and
///   only when the wording has actually changed. Standing in front of the same group in
///   silence is correct behaviour.
/// - A crowd gone for `clearAfter` is forgotten, so meeting one again is news.
struct CrowdAnnouncer: Sendable {
    /// Shortest gap between two crowd mentions.
    var minimumInterval: TimeInterval = 15
    /// How far off straight ahead a crowd can be and still be worth mentioning, in degrees.
    var maximumBearing: Double = 45
    /// Crowds further than this are not mentioned, in metres.
    var maximumDistance: Double = 8
    /// How long a crowd must be out of view before it counts as a new one.
    var clearAfter: TimeInterval = 3
    /// An announcement not delivered within this long is stale.
    var announcementLifetime: TimeInterval = 4

    private var spokenText: String?
    private var lastSpoken: TimeInterval = -.infinity
    private var lastSeen: TimeInterval = -.infinity

    init() {}

    /// Updates the state with one frame's crowds and returns what should be announced.
    ///
    /// - Parameters:
    ///   - crowds: This frame's groups, from `detectCrowds`.
    ///   - time: The frame's capture time in seconds (`ARFrame.timestamp`).
    ///   - now: Wall-clock time, for the event's `createdAt` and `expiresAt`.
    mutating func announcements(
        for crowds: [CrowdRegion],
        at time: TimeInterval,
        now: Date = .now
    ) -> [AnnouncementEvent] {
        guard let crowd = crowds.first(where: {
            abs($0.bearing.degrees) <= maximumBearing && $0.nearestDistance <= maximumDistance
        }) else {
            if time - lastSeen > clearAfter { spokenText = nil }
            return []
        }
        lastSeen = time

        let text = SpokenPhrasing.describe(crowd)
        let isFirstSighting = spokenText == nil
        let dueAgain = time - lastSpoken >= minimumInterval && text != spokenText
        guard isFirstSighting || dueAgain else { return [] }

        spokenText = text
        lastSpoken = time
        return [AnnouncementEvent(
            category: .ambient,
            priority: .normal,
            text: text,
            distance: crowd.nearestDistance,
            bearing: crowd.bearing,
            source: .sceneDescription,
            createdAt: now,
            expiresAt: now.addingTimeInterval(announcementLifetime),
            dedupKey: "crowd"
        )]
    }
}
