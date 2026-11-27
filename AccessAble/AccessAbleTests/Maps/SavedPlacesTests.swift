import Foundation
import Testing
@testable import AccessAble

@MainActor
struct SavedPlacesTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "SavedPlacesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private let clough = Destination(
        name: "Clough Undergraduate Learning Commons",
        coordinate: GeoCoordinate(latitude: 33.7749, longitude: -84.3964),
        address: "266 4th St NW, Atlanta, GA 30313"
    )

    private let dorm = Destination(
        name: "North Avenue Apartments",
        coordinate: GeoCoordinate(latitude: 33.7706, longitude: -84.3914),
        address: "120 North Ave NW, Atlanta, GA 30313"
    )

    @Test
    func sampleContentHasNoFakeSavedPlaces() {
        #expect(SampleContent.places.allSatisfy { !$0.isSaved })
    }

    @Test
    func saveWithOptionalLabelAndSurviveRelaunch() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let app = AppViewModel(defaults: defaults, services: .preview)
        #expect(app.savedPlaces.isEmpty)

        let savedDorm = app.savedPlacesStore.save(destination: dorm, label: "  Home  ")
        let savedClough = app.savedPlacesStore.save(destination: clough, label: "   ")

        #expect(savedDorm.label == "Home")
        #expect(savedDorm.displayName == "Home")
        #expect(savedDorm.subtitle == dorm.name)
        #expect(savedClough.label == nil)
        #expect(savedClough.displayName == clough.name)
        #expect(savedClough.subtitle == clough.address)

        let relaunched = AppViewModel(defaults: defaults, services: .preview)
        #expect(relaunched.savedPlaces.count == 2)
        #expect(relaunched.savedPlaces.map(\.displayName) == [clough.name, "Home"])
        #expect(relaunched.savedPlacesStore.savedPlace(matching: dorm)?.label == "Home")
        #expect(relaunched.savedPlacesStore.savedPlace(matching: clough)?.label == nil)
    }

    @Test
    func savingSameDestinationUpdatesInsteadOfDuplicating() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SavedPlacesStore(defaults: defaults)
        store.save(destination: clough, label: nil)
        store.save(destination: clough, label: "Class")

        #expect(store.places.count == 1)
        #expect(store.places.first?.displayName == "Class")
    }

    @Test
    func renameAndDeletePersistAcrossRelaunch() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SavedPlacesStore(defaults: defaults)
        let saved = store.save(destination: clough, label: "Class")
        let other = store.save(destination: dorm, label: "Home")

        store.rename(id: saved.id, to: "Study Spot")
        #expect(store.savedPlace(id: saved.id)?.displayName == "Study Spot")

        store.rename(id: saved.id, to: "   ")
        #expect(store.savedPlace(id: saved.id)?.label == nil)
        #expect(store.savedPlace(id: saved.id)?.displayName == clough.name)

        store.delete(id: other.id)

        let relaunched = SavedPlacesStore(defaults: defaults)
        #expect(relaunched.places.count == 1)
        #expect(relaunched.places.first?.id == saved.id)
        #expect(relaunched.places.first?.displayName == clough.name)
    }

    @Test
    func searchFindsSavedPlacesByLabelAndClearsNoResults() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SavedPlacesStore(defaults: defaults)
        store.save(destination: clough, label: "Class")
        store.save(destination: dorm, label: "Home")

        let search = PlaceSearchViewModel(places: SampleContent.places, savedPlaces: store)
        let listening = Task { await search.start() }
        defer { listening.cancel() }

        search.query = "Class"
        search.search()
        await waitUntil { !search.isSearching }

        #expect(search.matchingSavedPlaces.map(\.displayName) == ["Class"])
        #expect(!search.showsNoResults)
        #expect(search.resultsSummary == "1 saved place")

        search.query = "zzzz"
        search.search()
        await waitUntil { !search.isSearching }
        #expect(search.matchingSavedPlaces.isEmpty)
        #expect(search.showsNoResults)
    }

    @Test
    func savedPlacesComeBeforeLiveResults() async throws {
        let store = SavedPlacesStore(places: [])
        store.save(
            destination: Destination(
                name: "Campus Recreation Center",
                coordinate: GeoCoordinate(latitude: 33.775662, longitude: -84.404041),
                address: "750 Ferst Dr NW, Atlanta, GA"
            ),
            label: "Gym"
        )

        let search = PlaceSearchViewModel(savedPlaces: store)
        let listening = Task { await search.start() }
        defer { listening.cancel() }

        search.query = "Campus Rec"
        search.search()
        await waitUntil { !search.isSearching }

        #expect(search.matchingSavedPlaces.map(\.displayName) == ["Gym"])
        #expect(search.suggestions.map(\.title) == ["Campus Recreation Center"])
        #expect(search.resultsSummary == "1 saved place, 1 result")
    }

    @Test
    func signingOutClearsSavedPlaces() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SavedPlacesStore(defaults: defaults)
        store.save(destination: clough, label: "Class")
        let session = AccountSessionViewModel(
            auth: PlaceholderAuthService(), profiles: PlaceholderUserProfileStore(), savedPlaces: store
        )
        try await session.signOut()

        #expect(store.places.isEmpty)
        #expect(SavedPlacesStore(defaults: defaults).places.isEmpty)
    }

    @Test
    func undecodableStoredPlacesAreKeptAsideRatherThanOverwritten() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let backupKey = PlaceListDefaults.backupKey(for: "savedPlaces")
        let unreadable = Data("written by a newer build".utf8)
        defaults.set(unreadable, forKey: "savedPlaces")

        let store = SavedPlacesStore(defaults: defaults)
        #expect(store.places.isEmpty)
        store.save(destination: clough, label: "Class")

        #expect(defaults.data(forKey: backupKey) == unreadable)
        #expect(SavedPlacesStore(defaults: defaults).places.map(\.displayName) == ["Class"])

        // Signing out takes the kept-aside copy too.
        store.clear()
        #expect(defaults.data(forKey: backupKey) == nil)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        while !condition() { await Task.yield() }
    }

    @Test
    func originResultsUsesSavedPlacesFirst() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SavedPlacesStore(defaults: defaults)
        store.save(destination: dorm, label: "Home")

        let search = PlaceSearchViewModel(places: SampleContent.places, savedPlaces: store)
        #expect(search.originResults.map(\.displayName) == ["Home"])
        #expect(search.originResults.allSatisfy { $0.isSaved })

        search.originQuery = "Home"
        search.search()
        #expect(search.originResults.first?.displayName == "Home")
    }
}
