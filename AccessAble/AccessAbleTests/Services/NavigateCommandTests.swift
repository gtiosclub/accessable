import Foundation
import Synchronization
import Testing
@testable import AccessAble

/// Records what was said, in order.
private actor SpokenAnnouncements: AnnouncementEngineProtocol {
    private(set) var said: [String] = []

    func submit(_ event: AnnouncementEvent) async { said.append(event.text) }
    nonisolated func deliveredEvents() -> AsyncStream<AnnouncementEvent> { AsyncStream { $0.finish() } }
    func repeatLast() async {}
    func pause() async {}
    func resume() async {}
    func updateProfile(_ profile: GuidanceProfile) async {}
    func setInCall(_ inCall: Bool) async {}
}

/// Counts what it's asked to interpret.
private final class CountingCommands: CommandInterpreting {
    private let count = Mutex(0)
    var interpreted: Int { count.withLock { $0 } }

    func interpret(_ text: String) async -> VoiceCommand {
        count.withLock { $0 += 1 }
        return .unknown(text)
    }

    func answer(_ question: String, context: String?) async throws -> String { "" }
}

/// A trip whose state never arrives.
private final class SilentTrip: TripStateProviding {
    private let states = AsyncStream.makeStream(of: TripState.self)

    func tripStates() -> AsyncStream<TripState> { states.stream }
    func tripRoutes() -> AsyncStream<NavigationRoute?> { AsyncStream { $0.finish() } }
    func startTrip(route: NavigationRoute, destination: Destination, preferences: RoutePreferences,
                   resumingAtStep: Int?) async {}
    func pauseTrip() async {}
    func resumeTrip() async {}
    func endTrip() async {}
    func reroute() async {}
    func reportQuestionEnded(_ reportID: String, outcome: ReportQuestionOutcome) async {}
}

// MARK: - Keyword interpreter

struct NavigateKeywordTests {
    private let interpreter = KeywordCommandInterpreter()

    @Test(arguments: [
        "take me to Clough",
        "navigate to Clough",
        "go to Clough",
        "directions to Clough",
        "Take me to Clough.",
        "take me to Clough please",
        "Please take me to Clough!",
        "hey, can you take me to Clough?",
        "Could you navigate to Clough please?",
        "okay go to Clough",
    ])
    func parsesTheNavigatePhrases(_ phrase: String) async {
        #expect(await interpreter.interpret(phrase) == .navigate(to: "Clough"))
    }

    @Test(arguments: ["take me home", "Take me home, please.", "go home", "take me to home"])
    func parsesHome(_ phrase: String) async {
        #expect(await interpreter.interpret(phrase) == .navigate(to: "home"))
    }

    @Test
    func keepsTheCasingAndInnerPunctuation() async {
        #expect(await interpreter.interpret("TAKE ME TO St. Mary's Hall.") == .navigate(to: "St. Mary's Hall"))
    }

    @Test(arguments: ["how do I go to the library?", "What's the best way to go to class?"])
    func aQuestionStaysAQuestion(_ question: String) async {
        #expect(await interpreter.interpret(question) == .ask(question))
    }

    @Test(arguments: ["go", "go back", "go to settings", "Go to the settings.", "let's go"])
    func doesNotStealOtherCommands(_ text: String) async {
        #expect(await interpreter.interpret(text) == .unknown(text))
    }

    @Test
    func pauseIsStillPause() async {
        #expect(await interpreter.interpret("pause, then go to Clough") == .pauseTrip)
    }

    /// On Commands, "take me to the door" is a place to look up: the camera's "take me to the door"
    /// has its own field and never goes through the interpreter (see `cameraNavigationSkipsTheInterpreter`).
    @Test
    func theDoorIsAPlaceOnCommands() async {
        #expect(await interpreter.interpret("take me to the door") == .navigate(to: "the door"))
    }

    @Test
    func navigateDestinationFindsNothingInOtherText() {
        #expect(KeywordCommandInterpreter.navigateDestination(in: "describe my surroundings") == nil)
        #expect(KeywordCommandInterpreter.navigateDestination(in: "take me to ") == nil)
    }
}

// MARK: - Foundation Models mapping

struct NavigateGeneratedCommandTests {
    @Test
    func navigateToPlaceUsesThePlaceName() {
        let command = GeneratedCommand(action: .navigateToPlace, detail: "Clough")
        #expect(command.voiceCommand(original: "take me to Clough please") == .navigate(to: "Clough"))
    }

    @Test(arguments: ["", "  "])
    func anEmptyPlaceFallsBackToTheKeywordParse(_ detail: String) {
        let command = GeneratedCommand(action: .navigateToPlace, detail: detail)
        #expect(command.voiceCommand(original: "Take me to Clough please.") == .navigate(to: "Clough"))
    }

    @Test
    func anEmptyPlaceWithNoPhraseKeepsTheWholeText() {
        let command = GeneratedCommand(action: .navigateToPlace, detail: "")
        #expect(command.voiceCommand(original: "Clough") == .navigate(to: "Clough"))
    }
}

// MARK: - CommandViewModel

@MainActor
struct NavigateCommandTests {
    private let clough = Destination.at("Clough Undergraduate Learning Commons", 33.7749, -84.3964)
    private let threeClough = [
        Destination.at("Clough Commons", 1, 1), Destination.at("Clough Hall", 2, 2), Destination.at("Clough Annex", 3, 3),
    ]

    private func commands(
        _ lookup: DestinationLookup,
        trip: (any TripStateProviding)? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) -> CommandViewModel {
        var services = AppServices.preview
        services.commands = KeywordCommandInterpreter()
        if let trip { services.trip = trip }
        return CommandViewModel(services: services, destinations: lookup, clock: clock)
    }

    @Test
    func oneMatchOpensThePlace() async {
        let viewModel = commands(.fixed(nicknames: [DestinationCandidate(clough, names: [clough.name, "Clough"])]))
        var opened: Destination?
        viewModel.onOpenDestination = { opened = $0 }

        await viewModel.run("take me to Clough")

        #expect(opened == clough)
    }

    @Test
    func withoutARouterItSaysWhereToGo() async {
        let viewModel = commands(.fixed(nicknames: [DestinationCandidate(clough, names: [clough.name, "Clough"])]))
        await viewModel.run("take me to Clough")
        #expect(viewModel.lastReply == "Open Commands from Home to go to Clough Undergraduate Learning Commons.")
    }

    @Test
    func severalReadsTheTopThreeNumbered() async {
        let viewModel = commands(.fixed(mapKit: FixedMapKit((threeClough + [.at("Clough Way", 4, 4)]).map {
            DestinationCandidate($0)
        })))
        await viewModel.run("take me to Clough")
        #expect(viewModel.lastReply
            == "I found 3 places: 1, Clough Commons; 2, Clough Hall; 3, Clough Annex. Say the number or the name.")
    }

    @Test
    func noneSaysItCouldNotFindIt() async {
        let viewModel = commands(.fixed())
        await viewModel.run("take me to Nowhere")
        #expect(viewModel.lastReply == "I couldn't find Nowhere.")
    }

    @Test(arguments: [
        ("the first one", 0), ("number two", 1), ("2", 1), ("Third.", 2), ("Clough Annex", 2),
        ("take me to clough hall", 1), ("the second one please", 1),
    ])
    func theNextUtterancePicksFromThePlacesReadOut(_ utterance: String, _ index: Int) async {
        let mapKit = FixedMapKit(threeClough.map { DestinationCandidate($0) })
        let viewModel = commands(.fixed(mapKit: mapKit), clock: ManualClock())
        var opened: Destination?
        viewModel.onOpenDestination = { opened = $0 }

        await viewModel.run("take me to Clough")
        await viewModel.run(utterance)

        #expect(opened == threeClough[index])
        #expect(mapKit.searches == 1)
    }

    @Test
    func thePlacesReadOutExpireAfterAMinute() async {
        let clock = ManualClock()
        let viewModel = commands(.fixed(mapKit: FixedMapKit(threeClough.map { DestinationCandidate($0) })), clock: clock)
        var opened: Destination?
        viewModel.onOpenDestination = { opened = $0 }

        await viewModel.run("take me to Clough")
        clock.advance(by: CommandViewModel.choiceLifetime + .seconds(1))
        await viewModel.run("number two")

        #expect(opened == nil)
        #expect(viewModel.lastReply?.hasPrefix("Sorry, I didn't understand.") == true)
    }

    @Test
    func anythingElseForgetsThePlacesReadOut() async {
        let viewModel = commands(.fixed(mapKit: FixedMapKit(threeClough.map { DestinationCandidate($0) })),
                                 clock: ManualClock())
        var opened: Destination?
        viewModel.onOpenDestination = { opened = $0 }

        await viewModel.run("take me to Clough")
        await viewModel.run("where am I")
        await viewModel.run("2")

        #expect(opened == nil)
    }

    @Test
    func homeOpensTheSavedHome() async {
        let home = Destination.at("12 Main Street", 1, 1)
        let mapKit = FixedMapKit([DestinationCandidate(.at("Home", 2, 2))])
        let viewModel = commands(.fixed(saved: [DestinationCandidate(home, names: ["Home", home.name])], mapKit: mapKit))
        var opened: Destination?
        viewModel.onOpenDestination = { opened = $0 }

        await viewModel.run("take me home")

        #expect(opened == home)
        #expect(mapKit.searches == 0)
    }

    @Test
    func homeWithoutASavedHomeSaysSo() async {
        let mapKit = FixedMapKit([DestinationCandidate(.at("Home", 2, 2))])
        let viewModel = commands(.fixed(mapKit: mapKit))
        await viewModel.run("take me home")
        #expect(viewModel.lastReply == "You haven't saved a place called Home.")
        #expect(mapKit.searches == 0)
    }

    @Test
    func anOfflineSearchSaysSoNotNotFound() async {
        let viewModel = commands(.fixed(mapKit: FixedMapKit(error: PlaceLookupError.offline)))
        await viewModel.run("take me to Clough")
        #expect(viewModel.lastReply == "I couldn't search right now. Check your connection.")
    }

    @Test
    func anotherSearchFailureSaysSo() async {
        let viewModel = commands(.fixed(mapKit: FixedMapKit(error: PlaceLookupError.failed)))
        await viewModel.run("take me to Clough")
        #expect(viewModel.lastReply == "I couldn't search right now.")
    }

    @Test
    func aCancelledSearchSaysNothing() async {
        let viewModel = commands(.fixed(mapKit: FixedMapKit(error: CancellationError())))
        await viewModel.run("take me to Clough")
        #expect(viewModel.lastReply == nil)
    }

    @Test(arguments: [TripPhase.active, .paused])
    func onATripItDoesNotLookUp(_ phase: TripPhase) async {
        let mapKit = FixedMapKit([DestinationCandidate(clough)])
        let viewModel = commands(.fixed(mapKit: mapKit), trip: PreviewTripProvider(state: TripState(phase: phase)))
        var opened: Destination?
        viewModel.onOpenDestination = { opened = $0 }

        await viewModel.run("take me to Clough")

        #expect(viewModel.lastReply == "You're already on a trip. End it first to go somewhere else.")
        #expect(opened == nil)
        #expect(mapKit.searches == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func aTripStateThatNeverArrivesCountsAsNoTrip() async throws {
        let clock = ManualClock()
        let viewModel = commands(.fixed(nicknames: [DestinationCandidate(clough, names: ["Clough"])]),
                                 trip: SilentTrip(), clock: clock)
        var opened: Destination?
        viewModel.onOpenDestination = { opened = $0 }

        let run = Task { await viewModel.run("take me to Clough") }
        try await clock.waitForSleepers(1)
        clock.advance(by: CommandViewModel.tripStateWait)
        await run.value

        #expect(opened == clough)
    }

    @Test(.timeLimit(.minutes(1)))
    func leavingTheScreenDropsTheLookup() async {
        let mapKit = GatedMapKit()
        let viewModel = commands(.fixed(mapKit: mapKit))
        var opened: Destination?
        viewModel.onOpenDestination = { opened = $0 }

        let run = Task { await viewModel.run("take me to Clough") }
        await mapKit.waitUntilStarted()
        viewModel.cancelDictation()
        mapKit.release([DestinationCandidate(clough)])
        await run.value

        #expect(opened == nil)
        #expect(viewModel.lastReply == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aNewCommandDropsTheLookup() async {
        let mapKit = GatedMapKit()
        let viewModel = commands(.fixed(mapKit: mapKit))
        var opened: Destination?
        viewModel.onOpenDestination = { opened = $0 }

        let run = Task { await viewModel.run("take me to Clough") }
        await mapKit.waitUntilStarted()
        await viewModel.run("say something odd")
        let reply = viewModel.lastReply
        mapKit.release([DestinationCandidate(clough)])
        await run.value

        #expect(opened == nil)
        #expect(viewModel.lastReply == reply)
    }
}

// MARK: - Other screens

@MainActor
struct NavigateOtherScreensTests {
    @Test
    func duringATripNavigateDoesNotReplaceIt() async {
        let announcements = SpokenAnnouncements()
        var services = AppServices.preview
        services.commands = KeywordCommandInterpreter()
        services.announcements = announcements
        let session = TripSessionViewModel(
            plan: TripPlan(place: SampleContent.places[0], route: nil, isRecording: false),
            services: services, mayListenForAnswers: { false }
        )

        await session.respond(to: "take me to Clough")

        #expect(await announcements.said == ["You're already on a trip. End it first to go somewhere else."])
    }

    /// The camera's "take me to the door" steers to an object in view; it never reaches the command interpreter.
    @Test
    func cameraNavigationSkipsTheInterpreter() {
        let interpreter = CountingCommands()
        var services = AppServices.preview
        services.commands = interpreter
        let camera = LiveSceneViewModel(services: services)

        camera.navigate(to: "the door")

        #expect(interpreter.interpreted == 0)
    }
}
