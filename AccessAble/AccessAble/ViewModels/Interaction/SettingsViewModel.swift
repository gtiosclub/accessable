import Foundation
import Observation

/// The three lists of information topics on the Settings page.
enum InfoTopicList: CaseIterable, Sendable {
    case prioritized
    case unprompted
    case prompted

    /// These live on the `GuidanceProfile` rather than in `SettingsPreferences`, because the
    /// announcement engine reads the profile (T50).
    var keyPath: WritableKeyPath<GuidanceProfile, Set<InfoTopic>> {
        switch self {
        case .prioritized: \.prioritizedTopics
        case .unprompted: \.unpromptedTopics
        case .prompted: \.promptedTopics
        }
    }
}

/// Owner: User Interaction (3.3 / 3.4). Edits the shared GuidanceProfile, the settings-page
/// preferences, and the performance setting.
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

    var preferences: SettingsPreferences {
        get { app.preferences }
        set { app.preferences = newValue }
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

    func isSelected(_ topic: InfoTopic, in list: InfoTopicList) -> Bool {
        profile[keyPath: list.keyPath].contains(topic)
    }

    func toggle(_ topic: InfoTopic, in list: InfoTopicList) {
        if isSelected(topic, in: list) {
            profile[keyPath: list.keyPath].remove(topic)
        } else {
            profile[keyPath: list.keyPath].insert(topic)
        }
    }

    var autoRepeat: AutoRepeat {
        get { profile.autoRepeat }
        set { profile.autoRepeat = newValue }
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

    /// Restores everything on the Settings page. Keeps the user's vision level and resets the
    /// rest of the profile to that level's preset.
    func resetToDefaults() {
        profile = .preset(for: profile.visionLevel)
        preferences = .default
        performanceSetting = .automatic
    }
}
