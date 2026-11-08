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
