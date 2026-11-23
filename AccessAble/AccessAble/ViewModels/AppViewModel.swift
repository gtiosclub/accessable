import Foundation
import Observation
import UIKit

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

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tripCameraTask: Task<Void, Never>?
    /// So `preferences.usesSystemScreenReader` keeps matching the OS instead of freezing at
    /// whatever onboarding last recorded (task T51).
    @ObservationIgnored private var voiceOverObserver: NSObjectProtocol?

    private enum Keys {
        static let profile = "guidanceProfile"
        static let onboarded = "hasCompletedOnboarding"
        static let preferences = "settingsPreferences"
    }

    init(defaults: UserDefaults = .standard, services: AppServices? = nil) {
        self.defaults = defaults
        let performance = PerformanceModeMonitor()
        self.performance = performance
        self.services = services ?? .live(performance: performance)
        self.profile = Self.load(GuidanceProfile.self, forKey: Keys.profile, from: defaults) ?? .default
        self.preferences = Self.load(SettingsPreferences.self, forKey: Keys.preferences, from: defaults) ?? .default
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarded)

        let profile = self.profile
        self.services.askAISettings.priorities = profile.aiPriorities
        self.services.alertSettings.filter = profile.alertFilter
        self.services.alertSettings.soundCues = profile.channels.contains(.spatialAudio)
        let announcements = self.services.announcements
        Task { await announcements.updateProfile(profile) }

        let tripCamera = TripCameraCoordinator(trip: self.services.trip, scene: self.services.scene)
        tripCameraTask = Task { await tripCamera.run() }
        observeVoiceOverStatus()
    }

    isolated deinit {
        if let voiceOverObserver { NotificationCenter.default.removeObserver(voiceOverObserver) }
    }

    func completeOnboarding(with profile: GuidanceProfile) {
        self.profile = profile
        // Live system truth replaces onboarding's one-time self-report the moment onboarding
        // finishes; observeVoiceOverStatus() keeps it accurate for the rest of the app's life.
        preferences.usesSystemScreenReader = UIAccessibility.isVoiceOverRunning
        hasCompletedOnboarding = true
    }

    /// Keeps `preferences.usesSystemScreenReader` live instead of frozen at onboarding time
    /// (task T51): VoiceOver can be turned on or off from iOS Settings at any point while
    /// AccessAble is running, and the app should notice without needing a relaunch.
    private func observeVoiceOverStatus() {
        voiceOverObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.preferences.usesSystemScreenReader = UIAccessibility.isVoiceOverRunning
            }
        }
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
