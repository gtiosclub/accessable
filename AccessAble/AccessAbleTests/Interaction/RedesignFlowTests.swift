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
        let session = TripSessionViewModel(
            plan: plan, warningLifetime: .milliseconds(50), infoLifetime: .milliseconds(400)
        )
        session.add(TripAnnouncement(text: "Pillar ahead", kind: .warning))
        session.add(TripAnnouncement(text: "Turn left", kind: .info))
        try await Task.sleep(for: .milliseconds(200))
        // The warning has gone; the direction lasts longer.
        #expect(session.announcements.map(\.text) == ["Turn left"])
        try await Task.sleep(for: .milliseconds(500))
        #expect(session.announcements.isEmpty)
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

    @Test
    func resultsSettleAfterAPauseInTyping() async throws {
        let search = PlaceSearchViewModel()
        search.query = "CULC"
        #expect(search.isSearching)
        #expect(search.results.isEmpty)
        try await Task.sleep(for: PlaceSearchViewModel.debounce * 3)
        #expect(!search.isSearching)
        #expect(search.results.map(\.name).contains("CULC Room 152"))
        #expect(search.resultsSummary == "Showing \(search.results.count) of \(SampleContent.places.count) places")
    }

    @Test
    func categoriesCountWhatWasTyped() {
        let search = PlaceSearchViewModel()
        let parks = SampleContent.places.filter { $0.category == .parks }.count
        #expect(search.count(of: .parks) == parks)
        search.category = .parks
        #expect(search.isFiltering)
        #expect(search.results.allSatisfy { $0.category == .parks })
        search.clearFilters()
        #expect(!search.isFiltering)
        #expect(search.resultsSummary == "No places match")
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
