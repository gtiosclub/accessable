import Foundation
import Testing
@testable import AccessAble

@MainActor
struct CallerSettingsTests {
    @Test func callerPreferencesSurviveRelaunchWithoutRewritingGuidanceProfile() throws {
        let suite = "CallerSettingsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profileData = try JSONEncoder().encode(GuidanceProfile.blind)
        defaults.set(profileData, forKey: "guidanceProfile")
        let app = AppViewModel(defaults: defaults, services: .preview)
        let settings = SettingsViewModel(app: app)
        settings.callerPreferences = CallerPreferences(flashlightOnStart: true, criticalObstacleAlerts: false, announcementVolume: 0.3)
        let reloaded = AppViewModel(defaults: defaults, services: .preview)
        #expect(reloaded.callerPreferences == settings.callerPreferences)
        #expect(reloaded.services.callerSettings.preferences == settings.callerPreferences)
        #expect(defaults.data(forKey: "guidanceProfile") == profileData)
    }

    @Test func existingInstallsAndCorruptCallerDataUseSafeDefaults() {
        let suite = "CallerSettingsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = AppViewModel(defaults: defaults, services: .preview)
        #expect(initial.callerPreferences == CallerPreferences())
        defaults.set(Data("not JSON".utf8), forKey: "callerPreferences.v1")
        let recovered = AppViewModel(defaults: defaults, services: .preview)
        #expect(!recovered.callerPreferences.flashlightOnStart)
        #expect(recovered.callerPreferences.criticalObstacleAlerts)
    }

    @Test func resetIncludesCallerSettingsButGuidancePresetsDoNotOverwriteThem() {
        let suite = "CallerPresetTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppViewModel(defaults: defaults, services: .preview)
        let settings = SettingsViewModel(app: app)
        settings.callerPreferences.flashlightOnStart = true
        settings.callerPreferences.criticalObstacleAlerts = false
        settings.applyPreset(.lowVision)
        #expect(settings.callerPreferences.flashlightOnStart)
        settings.resetToDefaults()
        #expect(settings.callerPreferences == CallerPreferences())
        #expect(app.services.callerSettings.preferences == CallerPreferences())
    }

    @Test func volumeIsClampedAtTheSharedServiceBoundary() {
        let shared = CallerSettings()
        shared.preferences = CallerPreferences(announcementVolume: 2)
        #expect(shared.preferences.announcementVolume == 1)
        shared.preferences = CallerPreferences(announcementVolume: -1)
        #expect(shared.preferences.announcementVolume == 0)
        shared.preferences = CallerPreferences(announcementVolume: .nan)
        #expect(shared.preferences.announcementVolume == 1)
    }
}

struct CallAnnouncementPolicyTests {
    private func event(_ category: AnnouncementCategory, _ priority: AnnouncementPriority,
                       call: Bool = false) -> AnnouncementEvent {
        AnnouncementEvent(category: category, priority: priority, text: "fixture", source: .system, isCallAnnouncement: call)
    }

    @Test func disablingObstaclesOnlyFiltersCriticalHazardsDuringCalls() {
        let prefs = CallerPreferences(criticalObstacleAlerts: false)
        #expect(!CallAnnouncementPolicy.allows(event(.hazard, .critical), duringCall: true, preferences: prefs))
        #expect(CallAnnouncementPolicy.allows(event(.hazard, .critical), duringCall: false, preferences: prefs))
        #expect(CallAnnouncementPolicy.allows(event(.system, .critical), duringCall: true, preferences: prefs))
        #expect(CallAnnouncementPolicy.allows(event(.maneuver, .high), duringCall: true, preferences: prefs))
    }

    @Test func defaultsAllowCriticalHazardsButSuppressAmbientDuringCalls() {
        #expect(CallAnnouncementPolicy.allows(event(.hazard, .critical), duringCall: true, preferences: CallerPreferences()))
        #expect(!CallAnnouncementPolicy.allows(event(.ambient, .normal), duringCall: true, preferences: CallerPreferences()))
        #expect(CallAnnouncementPolicy.allows(event(.system, .high, call: true), duringCall: true, preferences: CallerPreferences()))
    }

    @Test func volumeAffectsCallPromptsAndInCallEventsButNotOrdinaryGuidance() {
        let prefs = CallerPreferences(announcementVolume: 0.2)
        #expect(CallAnnouncementPolicy.volume(for: event(.system, .high, call: true), duringCall: false, preferences: prefs) == 0.2)
        #expect(CallAnnouncementPolicy.volume(for: event(.maneuver, .high), duringCall: true, preferences: prefs) == 0.2)
        #expect(CallAnnouncementPolicy.volume(for: event(.maneuver, .high), duringCall: false, preferences: prefs) == 1)
    }
}
