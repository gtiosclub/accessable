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
    func searchFindsSavedPlacesByLabelAndClearsNoResults() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SavedPlacesStore(defaults: defaults)
        store.save(destination: clough, label: "Class")
        store.save(destination: dorm, label: "Home")

        let search = PlaceSearchViewModel(places: SampleContent.places, savedPlaces: store)
        search.query = "Class"
        search.search()

        #expect(search.matchingSavedPlaces.map(\.displayName) == ["Class"])
        #expect(!search.showsNoResults)
        #expect(search.resultsSummary == "1 saved place")

        search.query = "zzzz"
        search.search()
        #expect(search.matchingSavedPlaces.isEmpty)
        #expect(search.showsNoResults)
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
