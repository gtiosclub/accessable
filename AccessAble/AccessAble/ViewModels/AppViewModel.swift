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
            services.distanceSettings.units = profile.distanceUnits
            Task { await services.announcements.updateProfile(profile) }
        }
    }

    /// Settings-page choices that are not part of the GuidanceProfile.
    var preferences: SettingsPreferences {
        didSet { save(preferences, forKey: Keys.preferences) }
    }

    /// Kept separately so older GuidanceProfile and SettingsPreferences data still decode.
    var callerPreferences: CallerPreferences {
        get { services.callerSettings.preferences }
        set {
            services.callerSettings.preferences = newValue
            save(newValue.normalized, forKey: Keys.callerPreferences)
        }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarded) }
    }

    let performance: PerformanceModeMonitor
    let services: AppServices

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tripCameraTask: Task<Void, Never>?
    @ObservationIgnored private var tripActivityTask: Task<Void, Never>?
    @ObservationIgnored private let foregrounds: AsyncStream<Void>.Continuation

    private enum Keys {
        static let profile = "guidanceProfile"
        static let onboarded = "hasCompletedOnboarding"
        static let preferences = "settingsPreferences"
        static let callerPreferences = "callerPreferences.v1"
    }

    init(defaults: UserDefaults = .standard, services: AppServices? = nil) {
        self.defaults = defaults
        let performance = PerformanceModeMonitor()
        self.performance = performance
        self.services = services ?? .live(performance: performance)
        self.profile = Self.load(GuidanceProfile.self, forKey: Keys.profile, from: defaults) ?? .default
        self.preferences = Self.load(SettingsPreferences.self, forKey: Keys.preferences, from: defaults) ?? .default
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarded)
        let (foregroundStream, foregrounds) = AsyncStream<Void>.makeStream()
        self.foregrounds = foregrounds
        self.services.callerSettings.preferences = Self.load(CallerPreferences.self, forKey: Keys.callerPreferences, from: defaults) ?? CallerPreferences()

        let profile = self.profile
        self.services.askAISettings.priorities = profile.aiPriorities
        self.services.alertSettings.filter = profile.alertFilter
        self.services.alertSettings.soundCues = profile.channels.contains(.spatialAudio)
        self.services.distanceSettings.units = profile.distanceUnits
        let announcements = self.services.announcements
        Task { await announcements.updateProfile(profile) }

        let tripCamera = TripCameraCoordinator(trip: self.services.trip, camera: self.services.tripCamera)
        tripCameraTask = Task { await tripCamera.run() }
        let tripActivity = TripActivityController(
            trip: self.services.trip, activity: self.services.tripActivity, distances: self.services.distanceSettings,
            foregrounds: foregroundStream
        )
        tripActivityTask = Task { await tripActivity.run() }
    }

    /// A trip's Live Activity can only start in the foreground, so one that failed in the background starts now.
    func appBecameActive() {
        foregrounds.yield()
    }

    func completeOnboarding(with profile: GuidanceProfile) {
        self.profile = profile
        hasCompletedOnboarding = true
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
        let vm = AppViewModel(defaults: UserDefaults(suiteName: "preview") ?? .standard, services: .preview)
        vm.hasCompletedOnboarding = true
        return vm
    }
}
