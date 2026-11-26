import Foundation
import Observation

/// Edits the route preferences in Settings; each change goes straight to the store.
@MainActor
@Observable
final class RoutePreferencesViewModel {
    @ObservationIgnored private let store: RoutePreferencesStore

    var preferences: RoutePreferences {
        didSet { store.update(preferences) }
    }

    init(store: RoutePreferencesStore) {
        self.store = store
        preferences = store.current
    }
}
