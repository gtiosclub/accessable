import Foundation
import Observation

/// App-wide state: the user's GuidanceProfile, onboarding status, performance mode, and the service container.
/// Injected into the view hierarchy with `.environment(appViewModel)`.
@MainActor
@Observable
final class AppViewModel {
    var profile: GuidanceProfile {
        didSet {
            save(profile, forKey: Keys.profile)
            let profile = profile
            services.askAISettings.priorities = profile.aiPriorities
            services.alertSettings.filter = profile.alertFilter
            services.alertSettings.soundCues = profile.channels.contains(.spatialAudio)
            Self.applyHaptics(profile)
            infoTags.isVolunteer = profile.visionLevel == .sighted
            Task { await services.announcements.updateProfile(profile) }
        }
    }

    /// Settings-page choices that are not part of the GuidanceProfile.
    var preferences: SettingsPreferences {
        didSet { save(preferences, forKey: Keys.preferences) }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarded) }
    }

    let performance: PerformanceModeMonitor
    let services: AppServices
    /// NFC info tags shown on every map. Put in the environment by RootView.
    let infoTags: InfoTagsModel

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tripCameraTask: Task<Void, Never>?

    private enum Keys {
        static let profile = "guidanceProfile"
        static let onboarded = "hasCompletedOnboarding"
        static let preferences = "settingsPreferences"
    }

    init(
        defaults: UserDefaults = .standard,
        services: AppServices? = nil,
        infoTagRepository: (any InfoTagRepository)? = nil
    ) {
        self.defaults = defaults
        let performance = PerformanceModeMonitor()
        self.performance = performance
        self.services = services ?? .live(performance: performance)
        // TODO: swap LocalInfoTagRepository for the Firebase one so tags are shared between phones.
        self.infoTags = InfoTagsModel(
            repository: infoTagRepository ?? LocalInfoTagRepository(),
            scanner: CoreNFCTagScanner(),
            location: self.services.location,
            announcements: self.services.announcements
        )
        self.profile = Self.load(GuidanceProfile.self, forKey: Keys.profile, from: defaults) ?? .default
        self.preferences = Self.load(SettingsPreferences.self, forKey: Keys.preferences, from: defaults) ?? .default
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarded)

        let profile = self.profile
        self.services.askAISettings.priorities = profile.aiPriorities
        self.services.alertSettings.filter = profile.alertFilter
        self.services.alertSettings.soundCues = profile.channels.contains(.spatialAudio)
        Self.applyHaptics(profile)
        self.infoTags.isVolunteer = profile.visionLevel == .sighted
        let announcements = self.services.announcements
        Task { await announcements.updateProfile(profile) }

        let tripCamera = TripCameraCoordinator(trip: self.services.trip, scene: self.services.scene)
        tripCameraTask = Task { await tripCamera.run() }
    }

    func completeOnboarding(with profile: GuidanceProfile) {
        self.profile = profile
        hasCompletedOnboarding = true
    }

    /// Tap and app-feedback haptics follow the same Haptics switch and strength as guidance.
    private static func applyHaptics(_ profile: GuidanceProfile) {
        Haptics.isEnabled = profile.channels.contains(.haptics)
        Haptics.intensity = profile.hapticIntensity
    }

    // MARK: - Persistence

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

extension AppViewModel {
    /// In-memory, already-onboarded instance for SwiftUI previews.
    static var preview: AppViewModel {
        let vm = AppViewModel(
            defaults: UserDefaults(suiteName: "preview") ?? .standard,
            services: .preview,
            infoTagRepository: InMemoryInfoTagRepository()
        )
        vm.hasCompletedOnboarding = true
        return vm
    }
}
