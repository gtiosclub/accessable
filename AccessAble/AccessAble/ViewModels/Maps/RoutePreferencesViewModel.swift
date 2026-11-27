import Foundation
import Observation

/// Edits the route preferences in Settings; each change goes straight to the store.
@MainActor
@Observable
final class RoutePreferencesViewModel {
    @ObservationIgnored private let store: RoutePreferencesStore
    private var shown: RoutePreferences

    var preferences: RoutePreferences {
        get { shown }
        set {
            shown = newValue
            store.update(newValue)
        }
    }

    init(store: RoutePreferencesStore) {
        self.store = store
        shown = store.current
    }

    /// Follows the store, so a download at sign-in shows here and the next change starts from it.
    func listen() async {
        for await preferences in store.changes() {
            shown = preferences
        }
    }
}
