import Foundation
import Synchronization

/// Device preferences; separate from the cross-team GuidanceProfile contract.
struct CallerPreferences: Codable, Equatable, Sendable {
    var flashlightOnStart = false
    var criticalObstacleAlerts = true
    var announcementVolume: Float = 1

    var normalized: CallerPreferences {
        var value = self
        value.announcementVolume = announcementVolume.isFinite ? min(max(announcementVolume, 0), 1) : 1
        return value
    }
}

/// One shared snapshot for Settings, the call model and the announcement actor.
final class CallerSettings: Sendable {
    private let state = Mutex(CallerPreferences())
    var preferences: CallerPreferences {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue.normalized } }
    }
}

/// Pure policy used at submission, repeat and delivery, so queued alerts obey the latest setting.
enum CallAnnouncementPolicy {
    static func allows(_ event: AnnouncementEvent, duringCall: Bool, preferences: CallerPreferences) -> Bool {
        guard duringCall else { return true }
        if event.isCallAnnouncement || event.category == .maneuver { return true }
        if event.category == .hazard && event.priority == .critical { return preferences.criticalObstacleAlerts }
        return event.priority == .critical
    }

    static func volume(for event: AnnouncementEvent, duringCall: Bool, preferences: CallerPreferences) -> Float {
        event.isCallAnnouncement || duringCall ? preferences.normalized.announcementVolume : 1
    }
}
