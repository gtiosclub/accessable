import Foundation
import Testing
@testable import AccessAble

@MainActor
@Suite("Recent places (SEARCH-12)")
struct RecentPlacesTests {
    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "com.accessable.tests.recent.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func destination(_ name: String, offset: Double = 0) -> Destination {
        Destination(
            name: name,
            coordinate: GeoCoordinate(latitude: 33.7749 + offset, longitude: -84.3964 - offset),
            address: "\(Int(100 + offset * 1000)) Ferst Dr NW, Atlanta, GA"
        )
    }

    @Test
    func sampleContentHasNoFakeRecents() {
        #expect(SampleContent.places.allSatisfy { !$0.isRecent })
    }

    @Test
    func startingTripRecordsRecentAndSurvivesRelaunch() async {
        let defaults = freshDefaults()
        let firstApp = AppViewModel(defaults: defaults, services: .preview)
        let place = SampleContent.places[0]
        let plan = TripPlan(place: place, route: nil, isRecording: false)

        let session = TripSessionViewModel(plan: plan, recentPlaces: firstApp.recentPlacesStore)
        await session.run()

        #expect(firstApp.recentPlaces.count == 1)
        #expect(firstApp.recentPlaces.first?.name == place.name)

        // Relaunch with the same UserDefaults
        let relaunchedApp = AppViewModel(defaults: defaults, services: .preview)
        #expect(relaunchedApp.recentPlaces.count == 1)
        #expect(relaunchedApp.recentPlaces.first?.name == place.name)
        #expect(relaunchedApp.recentPlaces.first?.address == place.address)
    }

    @Test
    func repeatedPlaceMovesToTopInsteadOfDuplicating() async {
        let defaults = freshDefaults()
        let store = RecentPlacesStore(defaults: defaults)
        let library = SampleContent.places[0]
        let studentCenter = SampleContent.places[1]

        await TripSessionViewModel(
            plan: TripPlan(place: library, route: nil, isRecording: false),
            recentPlaces: store
        ).run()
        await TripSessionViewModel(
            plan: TripPlan(place: studentCenter, route: nil, isRecording: false),
            recentPlaces: store
        ).run()
        await TripSessionViewModel(
            plan: TripPlan(place: library, route: nil, isRecording: false),
            recentPlaces: store
        ).run()

        #expect(store.places.map(\.name) == [library.name, studentCenter.name])
    }

    @Test
    func capsAtTenMostRecentDestinations() {
        let defaults = freshDefaults()
        let store = RecentPlacesStore(defaults: defaults)

        for index in 1 ... 12 {
            store.record(destination: destination("Building \(index)", offset: Double(index) * 0.001))
        }

        #expect(store.places.count == 10)
        #expect(store.places.first?.name == "Building 12")
        #expect(store.places.last?.name == "Building 3")

        let reloaded = RecentPlacesStore(defaults: defaults)
        #expect(reloaded.places.map(\.name) == (3 ... 12).reversed().map { "Building \($0)" })
    }

    @Test
    func clearRecentsEmptiesAndPersistsAcrossRelaunch() {
        let defaults = freshDefaults()
        let store = RecentPlacesStore(defaults: defaults)
        store.record(destination: destination("Clough Commons"))
        store.record(destination: destination("Tech Green", offset: 0.002))
        #expect(store.places.count == 2)

        store.clear()
        #expect(store.places.isEmpty)

        let reloaded = RecentPlacesStore(defaults: defaults)
        #expect(reloaded.places.isEmpty)
    }

    @Test
    func searchExposesFiltersAndClearsRecents() async throws {
        let defaults = freshDefaults()
        let store = RecentPlacesStore(defaults: defaults)
        store.record(destination: destination("Bobby Dodd Stadium", offset: 0.003), category: .labeledPlaces)

        let search = PlaceSearchViewModel(recentPlaces: store)
        #expect(search.recentPlaces.map(\.name) == ["Bobby Dodd Stadium"])

        let listening = Task { await search.start() }
        defer { listening.cancel() }

        search.query = "Bobby"
        search.search()
        try await Task.sleep(for: .milliseconds(50))

        #expect(search.matchingRecentPlaces.map(\.name) == ["Bobby Dodd Stadium"])
        #expect(!search.showsNoResults)

        search.clearRecents()
        #expect(search.recentPlaces.isEmpty)
        #expect(search.matchingRecentPlaces.isEmpty)
    }
}
