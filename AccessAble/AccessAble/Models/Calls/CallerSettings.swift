import Foundation
import Synchronization

/// Device preferences; separate from the cross-team GuidanceProfile contract.
struct CallerPreferences: Codable, Equatable, Sendable {
    var flashlightOnStart = false
    var criticalObstacleAlerts = true
    var announcementVolume: Float = 1

    /// Never silent: a blind caller relies on hearing "Call ended" and failure prompts.
    static let minimumVolume: Float = 0.1

    var normalized: CallerPreferences {
        var value = self
        value.announcementVolume = announcementVolume.isFinite
            ? min(max(announcementVolume, Self.minimumVolume), 1) : 1
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

    /// Call prompts and in-call guidance are quieter so they don't drown out the volunteer;
    /// critical alerts are always full volume.
    static func volume(for event: AnnouncementEvent, duringCall: Bool, preferences: CallerPreferences) -> Float {
        guard event.priority != .critical else { return 1 }
        return event.isCallAnnouncement || duringCall ? preferences.normalized.announcementVolume : 1
    }
}
