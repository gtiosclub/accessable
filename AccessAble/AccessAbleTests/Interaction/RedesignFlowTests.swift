import Foundation
import Testing
@testable import AccessAble

@MainActor
struct OnboardingViewModelTests {
    @Test
    func walksThroughEveryStepInOrder() {
        let viewModel = OnboardingViewModel()
        #expect(viewModel.step == .role)

        viewModel.chooseRole(.sighted)
        #expect(viewModel.step == .voiceOver)
        #expect(viewModel.profile == .sightedHelper)

        viewModel.answerVoiceOver(false)
        #expect(viewModel.step == .tutorial)
        #expect(viewModel.usesVoiceOver == false)

        viewModel.finishTutorial()
        #expect(viewModel.step == .complete)

        viewModel.repeatTutorial()
        #expect(viewModel.step == .tutorial)
    }

    @Test
    func blindUsersGetTheBlindPreset() {
        let viewModel = OnboardingViewModel()
        viewModel.chooseRole(.blind)
        #expect(viewModel.profile == .blind)
    }
}

@MainActor
struct TripSessionViewModelTests {
    private let plan = TripPlan(place: SampleContent.places[0], route: nil, isRecording: false)

    @Test
    func keepsOnlyTheMostRecentAnnouncements() {
        let session = TripSessionViewModel(plan: plan)
        for index in 0..<5 {
            session.add(TripAnnouncement(text: "Note \(index)", kind: .info))
        }
        #expect(session.announcements.count == TripSessionViewModel.visibleAnnouncementLimit)
        #expect(session.latestAnnouncement?.text == "Note 4")
        #expect(session.announcements.first?.text == "Note 2")
    }

    @Test
    func barsFadeAwayAfterTheirLifetime() async throws {
        // Lifetimes far apart, so a busy test machine can't blur them.
        let session = TripSessionViewModel(
            plan: plan, warningLifetime: .milliseconds(50), infoLifetime: .seconds(30)
        )
        session.add(TripAnnouncement(text: "Pillar ahead", kind: .warning))
        session.add(TripAnnouncement(text: "Turn left", kind: .info))
        try await Task.sleep(for: .seconds(1))
        // The warning has gone; the direction lasts longer.
        #expect(session.announcements.map(\.text) == ["Turn left"])

        let directions = TripSessionViewModel(plan: plan, infoLifetime: .milliseconds(50))
        directions.add(TripAnnouncement(text: "Turn left", kind: .info))
        try await Task.sleep(for: .seconds(1))
        #expect(directions.announcements.isEmpty)
    }

    @Test
    func helpPhrasesOpenCallHelp() {
        #expect(TripSessionViewModel.asksForHelp("Call help"))
        #expect(TripSessionViewModel.asksForHelp("please call for help now"))
        #expect(TripSessionViewModel.asksForHelp("Call a volunteer"))
        #expect(!TripSessionViewModel.asksForHelp("Is the door on my left?"))
    }

    @Test
    func repeatAsksForTheWarningOrTheLastThingSaid() {
        #expect(TripSessionViewModel.asksToRepeat("Repeat warning") == true)
        #expect(TripSessionViewModel.asksToRepeat("can you repeat the obstacle") == true)
        #expect(TripSessionViewModel.asksToRepeat("Repeat") == false)
        #expect(TripSessionViewModel.asksToRepeat("say that again") == false)
        #expect(TripSessionViewModel.asksToRepeat("Is there a warning sign?") == nil)
    }

    @Test
    func frontEndMicOnlyFlipsTheButton() async {
        let session = TripSessionViewModel(plan: plan)
        #expect(session.isMicOff)
        await session.toggleMicrophone()
        #expect(!session.isMicOff)
        #expect(!session.isListening)
    }

    @Test
    func frontEndOnlyIsNotSpokenByTheEngine() {
        #expect(!TripSessionViewModel(plan: plan).isSpokenByEngine)
        #expect(TripSessionViewModel(plan: plan).directionsStatus == nil)
    }

    @Test
    func describeCommandsAddTheirSampleResponse() {
        let session = TripSessionViewModel(plan: plan, announcements: [])
        #expect(session.run(.describeLocation))
        #expect(session.latestAnnouncement?.text == VoiceCommandHint.describeLocation.sampleResponse?.text)
        #expect(session.latestAnnouncement?.kind == .info)

        #expect(session.run(.repeatWarning))
        #expect(session.latestAnnouncement?.text == SampleContent.pillarWarning)
        #expect(session.latestAnnouncement?.kind == .warning)
    }

    @Test
    func callHelpIsLeftToTheScreen() {
        let session = TripSessionViewModel(plan: plan, announcements: [])
        #expect(!session.run(.callHelp))
        #expect(session.announcements.isEmpty)
    }

    @Test
    func pauseAndBlockedRouteAreExclusive() {
        let session = TripSessionViewModel(plan: plan)
        session.simulateBlockedRoute()
        #expect(session.isRouteBlocked)

        session.pause()
        #expect(session.isPaused)
        #expect(!session.isRouteBlocked)

        session.resume()
        #expect(!session.isPaused)
    }

    @Test
    func rerouteClearsTheBlockAndAnnouncesTheNewRoute() {
        let session = TripSessionViewModel(plan: plan, announcements: [])
        session.simulateBlockedRoute()
        session.reroute()
        #expect(!session.isRouteBlocked)
        #expect(session.latestAnnouncement?.kind == .info)
    }
}

@MainActor
struct AppRouterTests {
    @Test
    func pushPopAndReturnToLanding() {
        let router = AppRouter()
        router.push(.search)
        router.push(.callHelp)
        #expect(router.path == [.search, .callHelp])

        router.pop()
        #expect(router.path == [.search])

        router.push(.settings)
        router.popToRoot()
        #expect(router.path.isEmpty)
    }

    @Test
    func popOnEmptyPathDoesNothing() {
        let router = AppRouter()
        router.pop()
        #expect(router.path.isEmpty)
    }
}

struct SampleContentSearchTests {
    @Test
    func emptyQueryWithoutCategoryFindsNothing() {
        #expect(SampleContent.search("  ", category: nil).isEmpty)
    }

    @Test
    func buildingInitialsMatch() {
        let names = SampleContent.search("CULC", category: nil).map(\.name)
        #expect(names.contains("Clough Undergraduate Learning Commons"))
        #expect(names.contains("CULC Room 152"))
    }

    @Test
    func categoryAloneFiltersPlaces() {
        let parks = SampleContent.search("", category: .parks)
        #expect(!parks.isEmpty)
        #expect(parks.allSatisfy { $0.category == .parks })
    }

    @Test
    func queryAndCategoryCombine() {
        let results = SampleContent.search("North", category: .publicTransit)
        #expect(results.map(\.id) == ["na-station"])
    }

    @Test
    func recordedRoutesAlwaysOfferAtLeastOne() {
        let place = SampleContent.places.first { $0.recordedRouteCount == 0 }!
        #expect(SampleContent.routes(to: place, mode: .recorded).count == 1)
        #expect(SampleContent.routes(to: place, mode: .new).count == 3)
    }
}

@MainActor
struct PlaceSearchViewModelTests {
    private func names(_ name: String, _ query: String) -> [String] {
        PlaceSearchViewModel.matchedRanges(in: name, for: query).map { String(name[$0]) }
    }

    @Test
    func highlightsTheMatchedText() {
        #expect(names("CULC Room 152", "room") == ["Room"])
        #expect(names("Clough Undergraduate Learning Commons", "culc") == ["C", "U", "L", "C"])
        #expect(names("Clough Undergraduate Learning Commons", "xyz").isEmpty)
        #expect(names("Anything", "  ").isEmpty)
    }

    /// Polls until `condition` holds; a busy test machine can take a while, so up to 3 s.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test
    func resultsSettleAfterAPauseInTyping() async throws {
        let search = PlaceSearchViewModel()
        let listening = Task { await search.start() }
        defer { listening.cancel() }

        search.query = "library"
        #expect(search.isSearching)
        #expect(search.suggestions.isEmpty)
        try await waitUntil { !search.isSearching }
        #expect(search.suggestions.map(\.title) == ["Georgia Tech Library"])
        #expect(search.destinationSearch.resultsAnnouncement == "1 result for library")
        #expect(search.resultsSummary == "1 result for library")
    }

    @Test
    func saysWhenNothingMatches() async throws {
        let search = PlaceSearchViewModel()
        let listening = Task { await search.start() }
        defer { listening.cancel() }

        search.query = "zzzz"
        try await waitUntil { !search.isSearching }
        #expect(search.showsNoResults)
        #expect(search.destinationSearch.resultsAnnouncement == "No results for zzzz")
    }

    @Test
    func saysWhenSuggestionsCantLoad() async throws {
        let search = PlaceSearchViewModel(search: FailingDestinationSearch())
        let listening = Task { await search.start() }
        defer { listening.cancel() }

        search.query = "Clough"
        try await waitUntil { !search.isSearching }
        #expect(search.problem == .suggestionsUnavailable)
        #expect(!search.showsNoResults)
        #expect(search.destinationSearch.resultsAnnouncement == nil)
        #expect(search.resultsSummary == "No results")
    }

    @Test
    func pickingAResultResolvesARealDestination() async throws {
        let search = PlaceSearchViewModel()
        let listening = Task { await search.start() }
        defer { listening.cancel() }

        search.query = "student"
        try await waitUntil { !search.suggestions.isEmpty }
        let suggestion = try #require(search.suggestions.first)
        search.select(suggestion)
        try await waitUntil { search.selectedDestination != nil }
        #expect(search.selectedDestination?.name == "John Lewis Student Center")
        #expect(search.selectedDestination?.address == "351 Ferst Dr NW, Atlanta, GA")
    }

    @Test
    func categoriesSearchForThatKindOfPlace() {
        let search = PlaceSearchViewModel()
        search.category = .parks
        #expect(search.isFiltering)
        #expect(search.searchText == "parks")
        #expect(search.destinationSearch.query == "parks")
        search.query = "Clough"
        search.search()
        #expect(search.searchText == "Clough parks")
        search.clearFilters()
        #expect(!search.isFiltering)
        #expect(search.destinationSearch.query.isEmpty)
    }

    @Test
    func searchedPlacesCarryTheirDestinationToTheTrip() {
        let destination = Destination(
            name: "Clough Undergraduate Learning Commons",
            coordinate: GeoCoordinate(latitude: 33.7746, longitude: -84.3964)
        )
        let place = SamplePlace(destination: destination)
        #expect(place.name == destination.name)
        #expect(place.latitude == 33.7746)
        #expect(place.longitude == -84.3964)
        #expect(place.address.isEmpty)
        #expect(place.recordedRouteCount == 0)
    }

    @Test
    func fromIsMyLocationUntilAPlaceIsPicked() {
        let search = PlaceSearchViewModel()
        #expect(search.origin == .myLocation)
        #expect(!search.canSwap)
        #expect(search.originResults.allSatisfy { $0.isSaved })

        let library = SampleContent.places[0]
        search.chooseOrigin(.place(library))
        #expect(search.origin.place == library)
        #expect(search.canSwap)

        search.swap()
        #expect(search.origin == .myLocation)
        #expect(search.query == library.name)
        #expect(search.settledQuery == library.name)
    }

    @Test
    func distancesReadAsAWalk() {
        #expect(PlaceSearchViewModel.distanceText(metres: 352) == "350 m · about 5 min walk")
        #expect(PlaceSearchViewModel.distanceText(metres: 3) == "10 m · about 1 min walk")
        #expect(PlaceSearchViewModel.distanceText(metres: 1840) == "1.8 km · about 26 min walk")
    }
}

/// Suggestions that never load, as when the phone is offline.
@MainActor
private struct FailingDestinationSearch: DestinationSearching {
    private let results = Broadcaster<Result<[SearchSuggestion], DestinationSearchError>>()

    func suggestions() -> AsyncStream<Result<[SearchSuggestion], DestinationSearchError>> {
        results.stream()
    }

    func update(query: String) {
        results.send(.failure(.suggestionsUnavailable))
    }

    func resolve(_ suggestion: SearchSuggestion) async throws -> Destination {
        throw DestinationSearchError.noMatch
    }
}
