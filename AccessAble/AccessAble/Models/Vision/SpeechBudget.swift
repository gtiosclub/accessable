import Foundation

/// The one limit on how much the camera says, across every announcer. Owner: Computer Vision (1.1).
///
/// Each announcer (path, approach, crowd, camera hints, street signs, "take me to…") keeps
/// itself quiet, but none of them knows what the others just said, so together they could
/// talk without a break. This sits after all of them:
/// - At most one event per frame gets through: the most urgent.
/// - A spoken event within `minimumGap` of the last one is dropped unless it is more urgent
///   than that one was. "Stop" always gets through.
/// - Haptic-only events never use up the gap, since they say nothing.
struct SpeechBudget: Sendable {
    var minimumGap: TimeInterval = 3

    private var lastSpoken: TimeInterval = -.infinity
    private var lastPriority: AnnouncementPriority?

    init() {}

    /// What to deliver from one frame's events, at the frame's capture time.
    mutating func admit(_ events: [AnnouncementEvent], at time: TimeInterval) -> [AnnouncementEvent] {
        // max(by:) keeps the first of equals, so ties go to the order the announcers ran in.
        let spoken = events.filter { !$0.hapticOnly }.max { $0.priority < $1.priority }
        if let spoken, isAllowed(spoken.priority, at: time) {
            lastSpoken = time
            lastPriority = spoken.priority
            return [spoken]
        }
        return events.filter(\.hapticOnly).max { $0.priority < $1.priority }.map { [$0] } ?? []
    }

    private func isAllowed(_ priority: AnnouncementPriority, at time: TimeInterval) -> Bool {
        if priority == .critical || time - lastSpoken >= minimumGap { return true }
        return lastPriority.map { priority > $0 } ?? true
    }
}
