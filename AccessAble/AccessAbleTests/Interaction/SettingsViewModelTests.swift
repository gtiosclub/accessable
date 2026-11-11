import Foundation
import Testing
@testable import AccessAble

@MainActor
struct SettingsViewModelTests {
    private func makeApp() -> (AppViewModel, UserDefaults) {
        let suite = "SettingsViewModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (AppViewModel(defaults: defaults, services: .preview), defaults)
    }

    @Test
    func newUserStartsWithDefaultPreferences() {
        let (app, _) = makeApp()
        #expect(app.preferences == .default)
    }

    @Test
    func togglingATopicAddsThenRemovesIt() {
        let (app, _) = makeApp()
        let viewModel = SettingsViewModel(app: app)
        #expect(!viewModel.isSelected(.directions, in: .prompted))

        viewModel.toggle(.directions, in: .prompted)
        #expect(viewModel.isSelected(.directions, in: .prompted))
        #expect(app.preferences.promptedTopics.contains(.directions))

        viewModel.toggle(.directions, in: .prompted)
        #expect(!viewModel.isSelected(.directions, in: .prompted))
    }

    @Test
    func topicListsAreIndependent() {
        let (app, _) = makeApp()
        let viewModel = SettingsViewModel(app: app)
        viewModel.toggle(.structureBasics, in: .unprompted)

        #expect(viewModel.isSelected(.structureBasics, in: .unprompted))
        #expect(!viewModel.isSelected(.structureBasics, in: .prioritized))
    }

    @Test
    func preferencesSurviveRelaunch() {
        let (app, defaults) = makeApp()
        app.preferences.autoRepeat = .twice
        app.preferences.phoneAimingHelp = false

        let relaunched = AppViewModel(defaults: defaults, services: .preview)
        #expect(relaunched.preferences.autoRepeat == .twice)
        #expect(relaunched.preferences.phoneAimingHelp == false)
    }

    @Test
    func resetRestoresDefaultsAndKeepsVisionLevel() {
        let (app, _) = makeApp()
        let viewModel = SettingsViewModel(app: app)
        viewModel.applyPreset(.lowVision)
        viewModel.setChannel(.haptics, enabled: true)
        viewModel.preferences.autoRepeat = .threeTimes
        viewModel.toggle(.directions, in: .prioritized)
        viewModel.performanceSetting = .battery

        viewModel.resetToDefaults()

        #expect(viewModel.profile == .lowVision)
        #expect(viewModel.preferences == .default)
        #expect(viewModel.performanceSetting == .automatic)
    }
}
