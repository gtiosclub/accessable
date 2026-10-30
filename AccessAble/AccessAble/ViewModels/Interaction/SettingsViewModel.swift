import Foundation
import Observation

/// Owner: User Interaction (3.3 / 3.4). Edits the shared GuidanceProfile and performance setting.
@MainActor
@Observable
final class SettingsViewModel {
    @ObservationIgnored private let app: AppViewModel

    init(app: AppViewModel) {
        self.app = app
    }

    var profile: GuidanceProfile {
        get { app.profile }
        set { app.profile = newValue }
    }

    var performanceSetting: PerformanceModeSetting {
        get { app.performance.setting }
        set { app.performance.setting = newValue }
    }

    var currentPerformanceMode: PerformanceMode { app.performance.mode }

    func isEnabled(_ channel: GuidanceChannels) -> Bool {
        profile.channels.contains(channel)
    }

    func setChannel(_ channel: GuidanceChannels, enabled: Bool) {
        if enabled { profile.channels.insert(channel) } else { profile.channels.remove(channel) }
    }

    func isEnabled(_ category: AnnouncementCategory) -> Bool {
        profile.enabledCategories.contains(category)
    }

    func setCategory(_ category: AnnouncementCategory, enabled: Bool) {
        if enabled { profile.enabledCategories.insert(category) } else { profile.enabledCategories.remove(category) }
    }

    func applyPreset(_ level: VisionLevel) {
        // A preset sets how guidance is delivered, not what the user wants to hear about.
        let priorities = profile.aiPriorities
        profile = .preset(for: level)
        profile.aiPriorities = priorities
    }

    /// Drag-to-reorder for the Ask AI ranking (T23).
    func moveAIPriorities(from source: IndexSet, to destination: Int) {
        profile.aiPriorities.move(fromOffsets: source, toOffset: destination)
    }

    /// Moves an Ask AI category up (negative) or down (positive) in the ranking (T23).
    func moveAIPriority(_ category: AIInfoCategory, by offset: Int) {
        profile.aiPriorities.move(category, by: offset)
    }
}
