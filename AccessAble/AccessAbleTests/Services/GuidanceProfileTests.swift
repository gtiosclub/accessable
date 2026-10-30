import Foundation
import Testing
@testable import AccessAble

@MainActor
struct GuidanceProfileTests {
    @Test
    func profileSavedBeforeAIPrioritiesStillLoads() throws {
        var saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(GuidanceProfile.lowVision)) as? [String: Any])
        saved["aiPriorities"] = nil
        let profile = try JSONDecoder().decode(GuidanceProfile.self, from: JSONSerialization.data(withJSONObject: saved))
        #expect(profile.visionLevel == .lowVision)
        #expect(profile.aiPriorities == .default)
    }

    @Test
    func aiPrioritiesRoundTrip() throws {
        var profile = GuidanceProfile.blind
        profile.aiPriorities.move(.signsText, by: -3)
        let decoded = try JSONDecoder().decode(GuidanceProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
    }

    @Test
    func settingsReachAskAI() {
        let app = AppViewModel(defaults: UserDefaults(suiteName: "GuidanceProfileTests")!, services: .preview)
        app.profile.aiPriorities = AIPriorities(order: [.people])
        #expect(app.services.askAISettings.priorities.order.first == .people)
        UserDefaults().removePersistentDomain(forName: "GuidanceProfileTests")
    }

    @Test
    func presetKeepsTheRanking() {
        let app = AppViewModel(defaults: UserDefaults(suiteName: "GuidanceProfileTests")!, services: .preview)
        let settings = SettingsViewModel(app: app)
        settings.moveAIPriority(.landmarks, by: -4)
        settings.applyPreset(.sighted)
        #expect(app.profile.visionLevel == .sighted)
        #expect(app.profile.aiPriorities.order.first == .landmarks)
        UserDefaults().removePersistentDomain(forName: "GuidanceProfileTests")
    }
}
