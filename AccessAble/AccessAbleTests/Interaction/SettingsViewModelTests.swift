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
    func obstacleSettingsUpdateProfileAndCameraImmediately() {
        let (app, _) = makeApp()
        let viewModel = SettingsViewModel(app: app)
        for danger in DangerLevel.allCases {
            viewModel.minimumDanger = danger
            #expect(app.profile.alertFilter.minimumDanger == danger)
            #expect(app.services.alertSettings.filter.minimumDanger == danger)
        }
        for distance in AlertFilter.distanceChoices {
            viewModel.warningDistance = distance
            #expect(app.profile.alertFilter.maximumDistance == distance)
            #expect(app.services.alertSettings.filter.maximumDistance == distance)
        }
    }

    @Test
    func cameraMenuChangesAreVisibleInSettings() {
        let (app, _) = makeApp()
        let viewModel = SettingsViewModel(app: app)
        app.profile.alertFilter = AlertFilter(minimumDanger: .critical, maximumDistance: 4)
        #expect(viewModel.minimumDanger == .critical)
        #expect(viewModel.warningDistance == 4)
    }

    @Test
    func obstacleSettingsSurviveRelaunch() {
        let (app, defaults) = makeApp()
        let viewModel = SettingsViewModel(app: app)
        viewModel.minimumDanger = .high
        viewModel.warningDistance = 1.5
        let relaunched = AppViewModel(defaults: defaults, services: .preview)
        #expect(relaunched.profile.alertFilter == AlertFilter(minimumDanger: .high, maximumDistance: 1.5))
        #expect(relaunched.services.alertSettings.filter == relaunched.profile.alertFilter)
    }

    @Test
    func distanceUnitsOnlyChangePresentation() {
        let (app, _) = makeApp()
        let viewModel = SettingsViewModel(app: app)
        viewModel.warningDistance = 4
        viewModel.preferences.usesMetricUnits = false
        #expect(AlertFilter.distanceLabel(viewModel.warningDistance, usesMetricUnits: false) == "13.1 ft")
        #expect(AlertFilter.distanceLabel(2.5, usesMetricUnits: true) == "2.5 m")
        #expect(viewModel.warningDistance == 4)
        #expect(app.services.alertSettings.filter.maximumDistance == 4)
    }

    @Test
    func resetRestoresDefaultsAndKeepsVisionLevel() {
        let (app, defaults) = makeApp()
        let viewModel = SettingsViewModel(app: app)
        viewModel.applyPreset(.lowVision)
        viewModel.setChannel(.haptics, enabled: true)
        viewModel.preferences.autoRepeat = .threeTimes
        viewModel.toggle(.directions, in: .prioritized)
        viewModel.performanceSetting = .battery
        viewModel.minimumDanger = .critical
        viewModel.warningDistance = 4

        viewModel.resetToDefaults()

        #expect(viewModel.profile == .lowVision)
        #expect(viewModel.preferences == .default)
        #expect(viewModel.performanceSetting == .automatic)
        #expect(viewModel.minimumDanger == .medium)
        #expect(viewModel.warningDistance == 2.5)
        #expect(app.services.alertSettings.filter == .default)
        let relaunched = AppViewModel(defaults: defaults, services: .preview)
        #expect(relaunched.profile.alertFilter == .default)
        #expect(relaunched.services.alertSettings.filter == .default)
    }
}
