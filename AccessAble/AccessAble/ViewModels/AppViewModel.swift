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
            Task { await services.announcements.updateProfile(profile) }
        }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarded) }
    }

    let performance: PerformanceModeMonitor
    let services: AppServices

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let profile = "guidanceProfile"
        static let onboarded = "hasCompletedOnboarding"
    }

    init(defaults: UserDefaults = .standard, services: AppServices? = nil) {
        self.defaults = defaults
        let performance = PerformanceModeMonitor()
        self.performance = performance
        self.services = services ?? .live(performance: performance)
        self.profile = Self.load(GuidanceProfile.self, forKey: Keys.profile, from: defaults) ?? .default
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarded)

        let profile = self.profile
        let announcements = self.services.announcements
        Task { await announcements.updateProfile(profile) }
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
        let vm = AppViewModel(defaults: UserDefaults(suiteName: "preview") ?? .standard)
        vm.hasCompletedOnboarding = true
        return vm
    }
}
