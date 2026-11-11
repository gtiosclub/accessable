import Foundation

/// Decides when the path ahead is blocked with no way round, for the trip screen's "Route
/// Blocked Ahead" page. Owner: Computer Vision (1.1).
///
/// Reads `PathAssessment` from the occupancy map, not single detections: blocked means the
/// corridor is closed close ahead and no sidestep gets past (`ClearDirection.blocked`). It
/// has to stay that way for `holdFor`, so a person walking across or the phone dipping
/// doesn't open a full-screen page. Turning is not counted as a way round: on a route, the
/// way on is ahead, and a hallway corner is passed long before the hold runs out.
///
/// After the user answers the page (Continue Walking, Re-Route, Pause Trip), it stays quiet
/// for `snooze`, so the same obstacle doesn't bring it straight back.
struct RouteBlockDetector: Sendable {
    /// The blockage must be at most this far ahead, in metres.
    var blockedWithin: Float = 1.5
    /// Seconds the path must stay blocked before the page shows.
    var holdFor: TimeInterval = 3
    /// Seconds of quiet after the user answers the page.
    var snooze: TimeInterval = 30

    private var blockedSince: TimeInterval?
    private var quietUntil = -TimeInterval.infinity

    init() {}

    /// Feeds one frame's assessment; true on the frame the page should open.
    mutating func update(_ path: PathAssessment?, at time: TimeInterval) -> Bool {
        guard let path, path.clearDirection == .blocked,
              let distance = path.blockedDistance, distance <= blockedWithin
        else {
            blockedSince = nil
            return false
        }
        let since = blockedSince ?? time
        blockedSince = since
        guard time >= quietUntil, time - since >= holdFor else { return false }
        // Once shown, it needs a fresh hold to show again.
        blockedSince = nil
        quietUntil = time + snooze
        return true
    }

    /// The user answered the page: stay quiet for `snooze` from now.
    mutating func dismiss(at time: TimeInterval) {
        blockedSince = nil
        quietUntil = time + snooze
    }
}
