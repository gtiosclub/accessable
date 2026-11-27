import Foundation
import Synchronization
import Testing
@testable import AccessAble

/// Records what was said, in order.
private actor RecordingAnnouncements: AnnouncementEngineProtocol {
    private(set) var said: [String] = []

    func submit(_ event: AnnouncementEvent) async { said.append(event.text) }
    nonisolated func deliveredEvents() -> AsyncStream<AnnouncementEvent> { AsyncStream { $0.finish() } }
    func repeatLast() async {}
    func pause() async {}
    func resume() async {}
    func updateProfile(_ profile: GuidanceProfile) async {}
    func setInCall(_ inCall: Bool) async {}
}

/// Records what was said, and says each event only when the test lets it finish.
private actor HeldAnnouncements: AnnouncementEngineProtocol {
    private nonisolated let finished = Broadcaster<FinishedAnnouncement>()
    private var submitted: [AnnouncementEvent] = []

    func submit(_ event: AnnouncementEvent) async { submitted.append(event) }
    nonisolated func deliveredEvents() -> AsyncStream<AnnouncementEvent> { AsyncStream { $0.finish() } }
    nonisolated func finishedEvents() -> AsyncStream<FinishedAnnouncement> {
        finished.stream(bufferingPolicy: .unbounded)
    }
    func repeatLast() async {}
    func pause() async {}
    func resume() async {}
    func updateProfile(_ profile: GuidanceProfile) async {}
    func setInCall(_ inCall: Bool) async {}

    /// Ends what was submitted; `idle` says whether anything else is still waiting to be said.
    func finishAll(interrupted: Bool = false, idle: Bool = true) {
        for event in submitted {
            finished.send(FinishedAnnouncement(id: event.id, wasInterrupted: interrupted, isIdle: idle))
        }
    }

    /// Ends something else said after them, leaving nothing waiting.
    func finishOther() {
        finished.send(FinishedAnnouncement(id: UUID(), wasInterrupted: false, isIdle: true))
    }
}

/// Keeps every report submitted and vote sent; given a failure, throws it instead.
private actor CapturingReports: ReportService {
    struct Offline: Error {}
    struct Vote: Equatable {
        let reportID: String
        let isStillPresent: Bool
    }

    let failure: (any Error)?
    let voteFailure: (any Error)?
    /// What a vote says it did to the expiry.
    let extends: Bool
    private(set) var submitted: [Report] = []
    private(set) var votes: [Vote] = []

    init(failure: (any Error)? = nil, voteFailure: (any Error)? = nil, extends: Bool = false) {
        self.failure = failure
        self.voteFailure = voteFailure
        self.extends = extends
    }

    func submit(_ report: Report) async throws {
        if let failure { throw failure }
        submitted.append(report)
    }

    func reports(near coordinate: GeoCoordinate, radius: Double) async throws -> [Report] { submitted }
    func confirm(_ reportID: String, isStillPresent: Bool) async throws -> Bool {
        votes.append(Vote(reportID: reportID, isStillPresent: isStillPresent))
        if let voteFailure { throw voteFailure }
        return extends
    }
    nonisolated func reportChanges(near coordinate: GeoCoordinate, radius: Double) -> AsyncStream<[Report]> {
        AsyncStream { $0.finish() }
    }
}

/// Records what reached the command parser, the way into Ask AI.
private actor RecordingCommands: CommandInterpreting {
    private(set) var interpreted: [String] = []

    func interpret(_ text: String) async -> VoiceCommand {
        interpreted.append(text)
        return .unknown(text)
    }

    func answer(_ question: String, context: String?) async throws -> String { "" }
}

private struct SilentScene: SceneDescribing {
    func describeCurrentScene() async -> String { "" }
    func ask(_ question: String, locationContext: String?) async throws -> String { "An answer." }
}

/// One trip state and no route changes, then finishes, so `TripViewModel.start()` returns.
private struct FixedTrip: TripStateProviding {
    /// How the screen ended each question.
    final class EndedQuestions: Sendable {
        private let ended = Mutex<[String: ReportQuestionOutcome]>([:])

        func record(_ id: String, _ outcome: ReportQuestionOutcome) { ended.withLock { $0[id] = outcome } }
        var all: [String: ReportQuestionOutcome] { ended.withLock { $0 } }

        /// Waits a bounded while for the screen's call, which comes from a task of its own.
        func waitForAny() async {
            for _ in 0..<1000 where all.isEmpty { await Task.yield() }
        }
    }

    let state: TripState
    let ended = EndedQuestions()

    func reportQuestionEnded(_ reportID: String, outcome: ReportQuestionOutcome) async {
        ended.record(reportID, outcome)
    }

    func tripStates() -> AsyncStream<TripState> {
        AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    func tripRoutes() -> AsyncStream<NavigationRoute?> { AsyncStream { $0.finish() } }
    func startTrip(route: NavigationRoute, destination: Destination, preferences: RoutePreferences,
                   resumingAtStep: Int?) async {}
    func pauseTrip() async {}
    func resumeTrip() async {}
    func endTrip() async {}
    func reroute() async {}
}

/// Yields fixed fixes, then finishes.
private struct ScriptedLocation: LocationProvider {
    let samples: [LocationSample]

    func locationSamples() -> AsyncStream<LocationSample> {
        AsyncStream { continuation in
            samples.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func headingSamples() -> AsyncStream<HeadingSample> { AsyncStream { $0.finish() } }

    func authorizationStates() -> AsyncStream<LocationAuthorization> {
        AsyncStream { continuation in
            continuation.yield(.authorized(preciseAccuracy: true))
            continuation.finish()
        }
    }

    func requestAuthorization() async {}
}

private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let start = GeoCoordinate(latitude: 33.775, longitude: -84.399)
private let library = Destination(name: "Library", coordinate: GeoCoordinate(latitude: 33.7759, longitude: -84.399))
/// About 100 m due north.
private let route = try! NavigationRoute(coordinates: [start, library.coordinate], steps: [
    RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Walk north.", spokenInstruction: "Walk north."),
    RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "You have arrived."),
], estimatedDuration: 80)
private let preciseFix = LocationSample(coordinate: start, horizontalAccuracy: 5, timestamp: now)

@MainActor
struct TripSessionReportTests {
    private let announcements = RecordingAnnouncements()
    private let commands = RecordingCommands()

    private func activeTrip(walked: Double?) -> FixedTrip {
        FixedTrip(state: walked.map { TripState(phase: .active, distanceRemaining: route.totalDistance - $0) } ?? .idle)
    }

    /// A trip on `route` that has had `fixes`, `walked` metres along when given.
    private func makeSession(
        fixes: [LocationSample] = [preciseFix],
        walked: Double? = nil,
        reports: CapturingReports,
        signedIn: Bool = true,
        reportsAvailable: Bool = true,
        clock: ManualClock = ManualClock(),
        engine: (any AnnouncementEngineProtocol)? = nil,
        trip: FixedTrip? = nil,
        // the simulator's dictation would ask for permission
        mayListen: @escaping @MainActor () -> Bool = { false }
    ) async -> TripSessionViewModel {
        var services = AppServices.preview
        services.announcements = engine ?? announcements
        services.commands = commands
        services.sceneDescriber = SilentScene()
        services.auth = PlaceholderAuthService(signedIn: signedIn)
        services.reports = reports
        services.reportsAvailable = reportsAvailable
        services.location = ScriptedLocation(samples: fixes)
        services.trip = trip ?? activeTrip(walked: walked)
        let session = TripSessionViewModel(
            plan: TripPlan(place: SampleContent.places[0], route: nil, isRecording: false),
            services: services,
            now: { now },
            clock: clock,
            mayListenForAnswers: mayListen
        )
        session.directions?.use(PlannedRoute(destination: library, route: route, requestedAt: now))
        await session.directions?.start()
        return session
    }

    @Test
    func reportsTheProblemWhereTheUserIs() async throws {
        let reports = CapturingReports()
        let session = await makeSession(reports: reports)

        await session.submitReport(kind: .construction)

        let report = try #require(await reports.submitted.first)
        #expect(await reports.submitted.count == 1)
        #expect(report.kind == .construction)
        #expect(report.coordinate == start)
        #expect(report.createdAt == now)
        #expect(report.expiresAt.timeIntervalSince(report.createdAt) == ReportKind.construction.lifetime)
        #expect(report.reporterID == PlaceholderAuthService.sampleUser.id)
        #expect(await announcements.said == ["Reported construction. Thank you."])
    }

    /// The Route Blocked card's report goes where the blockage is, not a fixed 12 m on.
    @Test
    func reportsFromRouteBlockedGoJustAheadOnTheRoute() async throws {
        let reports = CapturingReports()
        let session = await makeSession(walked: 40, reports: reports)

        await session.submitReport(kind: .blockedPath, useRouteAhead: true)

        let report = try #require(await reports.submitted.first)
        let along = GeoMath.distance(from: start, to: report.coordinate)
        #expect(abs(along - (40 + TripSessionViewModel.reportAheadDistance)) < 0.1)
        #expect(TripSessionViewModel.reportAheadDistance == 1.5)
    }

    @Test
    func reportsAheadStopAtTheRouteEnd() async throws {
        let reports = CapturingReports()
        let session = await makeSession(walked: route.totalDistance - 0.5, reports: reports)

        await session.submitReport(kind: .blockedPath, useRouteAhead: true)

        let report = try #require(await reports.submitted.first)
        #expect(GeoMath.distance(from: library.coordinate, to: report.coordinate) < 0.01)
    }

    /// With no progress yet, the report goes where the user is.
    @Test
    func reportsAheadWithoutProgressGoWhereTheUserIs() async throws {
        let reports = CapturingReports()
        let session = await makeSession(reports: reports)

        await session.submitReport(kind: .blockedPath, useRouteAhead: true)

        #expect(try #require(await reports.submitted.first).coordinate == start)
    }

    @Test(arguments: [
        // a rough fix, good enough to plan a route from but not to mark a problem
        [LocationSample(coordinate: start, horizontalAccuracy: 50, timestamp: now)],
        // a precise fix from before the user walked on
        [LocationSample(coordinate: start, horizontalAccuracy: 5, timestamp: now.addingTimeInterval(-11))],
        [],
    ])
    func needsARecentPreciseFix(_ fixes: [LocationSample]) async {
        let reports = CapturingReports()
        let session = await makeSession(fixes: fixes, reports: reports)

        await session.submitReport(kind: .construction)

        #expect(await reports.submitted.isEmpty)
        #expect(await announcements.said == ["Your location isn't precise enough to report yet. Try again in a moment."])
    }

    @Test
    func signedOutAsksToSignIn() async {
        let reports = CapturingReports()
        let session = await makeSession(reports: reports, signedIn: false)

        await session.submitReport(kind: .construction)

        #expect(await reports.submitted.isEmpty)
        #expect(await announcements.said == ["Sign in to report a problem."])
    }

    @Test
    func aFailedSendSaysSo() async {
        let session = await makeSession(reports: CapturingReports(failure: CapturingReports.Offline()))

        await session.submitReport(kind: .construction)

        #expect(await announcements.said == ["I couldn't send that report. Check your connection and try again."])
    }

    @Test
    func aSecondReportInsideAMinuteSaysToWait() async {
        let session = await makeSession(reports: CapturingReports(failure: ReportServiceError.rateLimited))

        await session.submitReport(kind: .construction)

        #expect(await announcements.said == ["You just sent a report. Wait a minute before sending another."])
    }

    @Test
    func aSignedOutServiceAsksToSignIn() async {
        let session = await makeSession(reports: CapturingReports(failure: ReportServiceError.notSignedIn))

        await session.submitReport(kind: .construction)

        #expect(await announcements.said == ["Sign in to report a problem."])
    }

    @Test(arguments: [ReportServiceError.permissionDenied, .invalidReport])
    func aRefusedReportSaysItCouldNotBeSent(_ failure: ReportServiceError) async {
        let session = await makeSession(reports: CapturingReports(failure: failure))

        await session.submitReport(kind: .construction)

        #expect(await announcements.said == ["That report couldn't be sent."])
    }

    @Test
    func anOfflineReportSaysItIsSaved() async {
        let session = await makeSession(reports: CapturingReports(failure: ReportServiceError.queuedOffline))

        await session.submitReport(kind: .construction)

        #expect(await announcements.said == ["Saved. It will be sent when you're back online."])
    }

    /// While reporting isn't available, nothing is stored and the user is told.
    @Test
    func unavailableReportingStoresNothing() async {
        let reports = CapturingReports()
        let session = await makeSession(reports: reports, reportsAvailable: false)

        await session.submitReport(kind: .construction)
        await session.respond(to: "Report construction")
        await session.respond(to: "Report a problem")

        #expect(await reports.submitted.isEmpty)
        #expect(await announcements.said == Array(repeating: "Reporting isn't available yet.", count: 3))
        #expect(await commands.interpreted.isEmpty)
        #expect(!session.isReportingAvailable)
    }

    @Test
    func frontEndOnlyCannotReport() async {
        let session = TripSessionViewModel(plan: TripPlan(place: SampleContent.places[0], route: nil, isRecording: false))

        await session.submitReport(kind: .construction)

        #expect(!session.isReportingAvailable)
        #expect(session.latestAnnouncement?.text == "Reporting isn't available yet.")
    }

    @Test
    func aSpokenReportIsReportedNotAsked() async throws {
        let reports = CapturingReports()
        let session = await makeSession(reports: reports)

        await session.respond(to: "I want to report construction.")

        #expect(try #require(await reports.submitted.first).kind == .construction)
        #expect(await commands.interpreted.isEmpty)
    }

    @Test
    func aReportWithoutAKindAsksWhichOne() async {
        let reports = CapturingReports()
        let session = await makeSession(reports: reports)

        await session.respond(to: "Report a problem.")

        #expect(await reports.submitted.isEmpty)
        #expect(await announcements.said == [
            "What's the problem? Say report, then the problem: report construction, report blocked path, report closed entrance, report elevator, or report other."
        ])
        #expect(await commands.interpreted.isEmpty)
    }

    /// "Report" further in is a question, for Ask AI.
    @Test
    func aQuestionAboutAReportIsAsked() async {
        let reports = CapturingReports()
        let session = await makeSession(reports: reports)

        await session.respond(to: "What does this report say?")

        #expect(await reports.submitted.isEmpty)
        #expect(await commands.interpreted == ["What does this report say?"])
    }

    /// Tried from Voice Commands, the screen opens the report choices.
    @Test
    func theReportCommandIsLeftToTheScreen() async {
        let session = await makeSession(reports: CapturingReports())
        #expect(!session.run(.reportProblem))
        #expect(await announcements.said.isEmpty)
    }

    // MARK: Report questions

    private func question(
        _ kind: ReportKind = .blockedPath, by reporter: String = "neighbour", askedAt: Date = now
    ) -> ReportQuestion {
        ReportQuestion(report: Report(
            id: "passed", kind: kind, coordinate: start, createdAt: now.addingTimeInterval(-3600),
            expiresAt: now.addingTimeInterval(3600), reporterID: reporter
        ), askedAt: askedAt)
    }

    /// The question's answer window runs out. A sleep counted may be the speech limit's, cancelled as the question is
    /// said, so it goes round until the question has closed.
    private func runOutTheAnswerWindow(on clock: ManualClock, of session: TripSessionViewModel) async throws {
        while session.reportQuestion != nil {
            try await clock.waitForSleepers(1)
            clock.advance(by: TripSessionViewModel.answerWindow)
            for _ in 0..<100 where session.reportQuestion != nil { await Task.yield() }
        }
    }

    @Test(arguments: [
        (ReportKind.blockedPath, "Is the path still blocked here?"),
        (.construction, "Is the path still blocked here?"),
        (.closedEntrance, "Is the entrance still closed?"),
        (.elevatorOut, "Is the elevator still out of service?"),
        (.other, "Is the reported problem still there?"),
    ])
    func aQuestionIsWordedForItsKind(_ kind: ReportKind, _ text: String) async {
        let session = await makeSession(walked: 10, reports: CapturingReports())

        await session.askAbout(question(kind))

        #expect(await announcements.said == [text])
        #expect(session.reportQuestion == OpenReportQuestion(reportID: "passed", text: text))
        // buttons only: listening isn't allowed here
        #expect(!session.isListening)
    }

    @Test
    func aYesButtonVotesAndSaysTheReportIsConfirmed() async throws {
        let reports = CapturingReports()
        let session = await makeSession(walked: 10, reports: reports)
        await session.askAbout(question())
        let open = try #require(session.reportQuestion)

        await session.answer(open, isStillPresent: true)

        #expect(await reports.votes == [.init(reportID: "passed", isStillPresent: true)])
        #expect(await announcements.said.last == "Thanks, the report is confirmed.")
        #expect(session.reportQuestion == nil)
    }

    @Test
    func aYesThatExtendsTheReportSaysSo() async throws {
        let session = await makeSession(walked: 10, reports: CapturingReports(extends: true))
        await session.askAbout(question())

        await session.answer(try #require(session.reportQuestion), isStillPresent: true)

        #expect(await announcements.said.last == "Thanks, the report is extended.")
    }

    @Test
    func aNoButtonVotesAndSaysThanks() async throws {
        let reports = CapturingReports()
        let session = await makeSession(walked: 10, reports: reports)
        await session.askAbout(question())

        await session.answer(try #require(session.reportQuestion), isStillPresent: false)

        #expect(await reports.votes == [.init(reportID: "passed", isStillPresent: false)])
        #expect(await announcements.said.last == "Thanks.")
    }

    @Test
    func answeringTwiceVotesOnce() async throws {
        let reports = CapturingReports()
        let session = await makeSession(walked: 10, reports: reports)
        await session.askAbout(question())
        let open = try #require(session.reportQuestion)

        await session.answer(open, isStillPresent: true)
        await session.answer(open, isStillPresent: false)

        #expect(await reports.votes.count == 1)
    }

    /// A button pressed as the window closes still votes for the report it showed.
    @Test
    func aButtonPressedAsTheQuestionClosesStillVotes() async throws {
        let reports = CapturingReports()
        let clock = ManualClock()
        let session = await makeSession(walked: 10, reports: reports, clock: clock)
        await session.askAbout(question())
        let open = try #require(session.reportQuestion)
        try await runOutTheAnswerWindow(on: clock, of: session)

        await session.answer(open, isStillPresent: true)

        #expect(await reports.votes == [.init(reportID: "passed", isStillPresent: true)])
    }

    @Test(arguments: ["Yes.", "yeah", "Yep!", "Still there.", "It's still blocked"])
    func aSpokenYesInTheWindowVotes(_ words: String) async {
        let reports = CapturingReports()
        let session = await makeSession(walked: 10, reports: reports)
        await session.askAbout(question())

        await session.respond(to: words)

        #expect(await reports.votes == [.init(reportID: "passed", isStillPresent: true)])
        #expect(await commands.interpreted.isEmpty)
    }

    @Test(arguments: ["No.", "nope", "It's clear.", "Gone"])
    func aSpokenNoInTheWindowVotes(_ words: String) async {
        let reports = CapturingReports()
        let session = await makeSession(walked: 10, reports: reports)
        await session.askAbout(question())

        await session.respond(to: words)

        #expect(await reports.votes == [.init(reportID: "passed", isStillPresent: false)])
    }

    @Test
    func otherWordsInTheWindowAreNotAnAnswer() async {
        let reports = CapturingReports()
        let session = await makeSession(walked: 10, reports: reports)
        await session.askAbout(question())

        await session.respond(to: "Yes, what's that building?")

        #expect(await reports.votes.isEmpty)
        #expect(await commands.interpreted == ["Yes, what's that building?"])
    }

    @Test
    func noAnswerIsNoVoteAndAYesAfterTheWindowIsJustSpeech() async throws {
        let reports = CapturingReports()
        let clock = ManualClock()
        let session = await makeSession(walked: 10, reports: reports, clock: clock)
        await session.askAbout(question())

        try await runOutTheAnswerWindow(on: clock, of: session)
        await session.respond(to: "Yes")

        #expect(await reports.votes.isEmpty)
        #expect(await commands.interpreted == ["Yes"])
        // the question, then Ask AI's reply, and nothing about the report
        #expect(await announcements.said == ["Is the path still blocked here?", "An answer."])
    }

    @Test(arguments: [
        (ReportServiceError.rateLimited, "Wait a minute before answering again."),
        (.unavailable, "Couldn't send your answer."),
        (.permissionDenied, "Couldn't send your answer."),
        (.notSignedIn, "Couldn't send your answer."),
    ])
    func aFailedVoteSaysWhy(_ failure: ReportServiceError, _ text: String) async throws {
        let session = await makeSession(walked: 10, reports: CapturingReports(voteFailure: failure))
        await session.askAbout(question())

        await session.answer(try #require(session.reportQuestion), isStillPresent: true)

        #expect(await announcements.said.last == text)
    }

    @Test
    func theUsersOwnReportIsNotAskedAbout() async {
        let session = await makeSession(walked: 10, reports: CapturingReports())

        await session.askAbout(question(by: PlaceholderAuthService.sampleUser.id))

        #expect(session.reportQuestion == nil)
        #expect(await announcements.said.isEmpty)
    }

    /// One from before the screen was listening, such as the last trip's.
    @Test
    func anOldQuestionIsNotAsked() async {
        let session = await makeSession(walked: 10, reports: CapturingReports())

        await session.askAbout(question(askedAt: now.addingTimeInterval(-30)))

        #expect(session.reportQuestion == nil)
        #expect(await announcements.said.isEmpty)
    }

    @Test
    func noQuestionWhileReportingIsUnavailableOrTheTripIsntUnderway() async {
        let unavailable = await makeSession(walked: 10, reports: CapturingReports(), reportsAvailable: false)
        await unavailable.askAbout(question())
        let planning = await makeSession(reports: CapturingReports())
        await planning.askAbout(question())

        #expect(unavailable.reportQuestion == nil)
        #expect(planning.reportQuestion == nil)
        #expect(await announcements.said.isEmpty)
    }

    @Test
    func theAnswerWindowStartsOnceTheQuestionHasBeenSaid() async throws {
        let engine = HeldAnnouncements()
        let clock = ManualClock()
        let session = await makeSession(walked: 10, reports: CapturingReports(), clock: clock, engine: engine)
        await session.askAbout(question())

        // the speech limit, while the question waits to be said
        try await clock.waitForSleepers(1)
        clock.advance(by: TripSessionViewModel.answerWindow)
        for _ in 0..<100 { await Task.yield() }
        #expect(session.reportQuestion != nil)

        await engine.finishAll()
        try await runOutTheAnswerWindow(on: clock, of: session)
        #expect(session.reportQuestion == nil)
    }

    @Test(arguments: [
        ("Yes, it's still blocked.", true), ("Yeah, still blocked.", true), ("Yes it's still there.", true),
        ("Uh, yes.", true), ("Yup", true), ("The elevator is still out.", true),
        ("No, it's not.", false), ("No it's clear now.", false), ("Nope, it's gone.", false),
        ("It's gone now.", false), ("No, the path is clear.", false), ("Nah.", false), ("It's fixed.", false),
        // a "not" or "-n't" turns the words round
        ("It's still not working", true), ("The elevator still isn't working", true), ("Not working", true),
        ("It's not gone", true), ("It's not clear", true), ("It doesn't work.", true), ("It isn't open.", true),
        ("Not anymore.", false), ("No longer.", false), ("It's no longer blocked.", false),
        ("It isn't there anymore.", false), ("The entrance is open now.", false),
        ("They're still working on it.", true), ("Construction work is still going on.", true),
        ("It works.", false), ("It's working now.", false), ("Working again.", false),
        ("There's nothing there.", false), ("Nothing there.", false), ("Nothing's there anymore.", false),
        ("It's out of the way now.", false), ("Not bad, it's blocked.", true),
    ])
    func theQuestionsListeningTakesAnswersInWholeSentences(_ words: String, _ isStillPresent: Bool) async throws {
        let reports = CapturingReports()
        let session = await makeSession(walked: 10, reports: reports)
        await session.askAbout(question())

        await session.heardAnswer(words, to: try #require(session.reportQuestion))

        #expect(await reports.votes == [.init(reportID: "passed", isStillPresent: isStillPresent)])
    }

    /// Doubt, or words that say both, are no vote.
    @Test(arguments: ["No idea", "No clue.", "Not sure", "I don't know", "Maybe", "No it's still there",
                      "No wait, yes", "Yes, it's gone", "Hmm", "", "Yeah no", "Is it still there?", "Blocked?"])
    func doubtOrAContradictionIsNoAnswer(_ words: String) {
        #expect(TripSessionViewModel.reportAnswer(for: words) == nil)
    }

    /// The question's own listening only ever answers it: nothing heard there pauses, calls help, reports or asks.
    @Test
    func theQuestionsListeningDropsAnythingElseSayingSoOnce() async throws {
        let reports = CapturingReports()
        let session = await makeSession(walked: 10, reports: reports)
        var calledHelp = false
        session.onCallHelp = { calledHelp = true }
        await session.askAbout(question())
        let open = try #require(session.reportQuestion)

        for words in ["Get help", "Pause the trip", "Report construction", "What's that building?"] {
            await session.heardAnswer(words, to: open)
        }

        #expect(await reports.votes.isEmpty)
        #expect(await reports.submitted.isEmpty)
        #expect(!calledHelp)
        #expect(!session.isPaused)
        #expect(await commands.interpreted.isEmpty)
        #expect(await announcements.said == ["Is the path still blocked here?", "Didn't catch that."])
        #expect(session.reportQuestion == open)
    }

    @Test
    func theTripHearsWhenAQuestionEnds() async throws {
        let trip = activeTrip(walked: 10)
        let session = await makeSession(walked: 10, reports: CapturingReports(), trip: trip)
        await session.askAbout(question())

        await session.answer(try #require(session.reportQuestion), isStillPresent: true)

        await trip.ended.waitForAny()
        #expect(trip.ended.all == ["passed": .voted])
    }

    @Test
    func aVoteThatCantBeSentIsNoVoteToTheTrip() async throws {
        let trip = activeTrip(walked: 10)
        let session = await makeSession(
            walked: 10, reports: CapturingReports(voteFailure: ReportServiceError.unavailable), trip: trip
        )
        await session.askAbout(question())

        await session.answer(try #require(session.reportQuestion), isStillPresent: true)

        await trip.ended.waitForAny()
        #expect(trip.ended.all == ["passed": .unanswered])
    }

    @Test
    func theTripHearsWhenAQuestionRunsOut() async throws {
        let trip = activeTrip(walked: 10)
        let clock = ManualClock()
        let session = await makeSession(walked: 10, reports: CapturingReports(), clock: clock, trip: trip)
        await session.askAbout(question())

        try await runOutTheAnswerWindow(on: clock, of: session)

        await trip.ended.waitForAny()
        #expect(trip.ended.all == ["passed": .unanswered])
    }

    /// One not put to the user may be asked again.
    @Test
    func theTripHearsWhenAQuestionIsntAsked() async {
        let trip = activeTrip(walked: 10)
        let session = await makeSession(walked: 10, reports: CapturingReports(), trip: trip)

        await session.askAbout(question(askedAt: now.addingTimeInterval(-30)))

        #expect(trip.ended.all == ["passed": .notAsked])
    }

    /// Whether the question tried to listen, in place of the microphone.
    @MainActor
    private final class ListenAttempts {
        var count = 0
    }

    /// Asks with `engine`, counting when listening would start; it isn't allowed, so dictation never starts.
    private func askCountingListens(with engine: HeldAnnouncements, clock: ManualClock) async
        -> (TripSessionViewModel, ListenAttempts) {
        let attempts = ListenAttempts()
        let session = await makeSession(walked: 10, reports: CapturingReports(), clock: clock, engine: engine,
                                        mayListen: { attempts.count += 1; return false })
        await session.askAbout(question())
        return (session, attempts)
    }

    @Test
    func listeningWaitsForTheQuestionAndAnythingQueuedBehindIt() async throws {
        let engine = HeldAnnouncements()
        let (session, attempts) = await askCountingListens(with: engine, clock: ManualClock())

        await engine.finishAll(idle: false)
        for _ in 0..<100 { await Task.yield() }
        #expect(attempts.count == 0)

        await engine.finishOther()
        for _ in 0..<1000 where attempts.count == 0 { await Task.yield() }
        #expect(attempts.count == 1)
        #expect(session.reportQuestion != nil)
    }

    /// A warning cut the question off: listening would fight it for the audio, so there are only the buttons.
    @Test
    func aQuestionCutOffIsNotListenedFor() async throws {
        let engine = HeldAnnouncements()
        let clock = ManualClock()
        let (session, attempts) = await askCountingListens(with: engine, clock: clock)

        await engine.finishAll(interrupted: true)
        try await runOutTheAnswerWindow(on: clock, of: session)

        #expect(attempts.count == 0)
    }

    @Test
    func aQuestionNeverSaidIsNotListenedForButStillCloses() async throws {
        let engine = HeldAnnouncements()
        let clock = ManualClock()
        let (session, attempts) = await askCountingListens(with: engine, clock: clock)

        try await clock.waitForSleepers(1)
        clock.advance(by: TripSessionViewModel.questionSpeechLimit)
        try await runOutTheAnswerWindow(on: clock, of: session)

        #expect(attempts.count == 0)
    }

    @Test
    func noDidntCatchThatOnceTheQuestionHasGone() async throws {
        let clock = ManualClock()
        let session = await makeSession(walked: 10, reports: CapturingReports(), clock: clock)
        await session.askAbout(question())
        let open = try #require(session.reportQuestion)
        try await runOutTheAnswerWindow(on: clock, of: session)

        await session.heardAnswer("What's that?", to: open)

        #expect(await announcements.said == ["Is the path still blocked here?"])
    }

    // MARK: The map's label

    /// One 40 m ahead of a user 20 m along, and one 50 m east of where they are, off the route.
    private func mapReports() -> [Report] {
        [("ahead", ReportKind.blockedPath, TripWalk.point(on: route, along: 60)),
         ("east", .construction, TripWalk.destination(from: start, bearing: 90, distance: 50))].map { id, kind, at in
            Report(id: id, kind: kind, coordinate: at, createdAt: now, expiresAt: now.addingTimeInterval(3600),
                   reporterID: "user-1")
        }
    }

    /// Walking east, so the report east of the user is straight ahead of them.
    @Test
    func theMapSaysItsReportsFromTheWalkAndTheWayTheUserIsGoing() async {
        let walking = LocationSample(coordinate: start, horizontalAccuracy: 5, timestamp: now, speed: 1.4, course: 90)
        let session = await makeSession(fixes: [walking], walked: 20, reports: CapturingReports())

        session.showOnMap(mapReports())

        #expect(session.mapAccessibilityLabel == "Map showing walking directions to Library. 2 reports on or near "
            + "your route: blocked path, 40 metres ahead on your route; construction, 50 metres at 12 o'clock.")
    }

    @Test(arguments: [
        // standing, the course is wherever the phone drifted
        LocationSample(coordinate: start, horizontalAccuracy: 5, timestamp: now, speed: 0.2, course: 90),
        LocationSample(coordinate: start, horizontalAccuracy: 5, timestamp: now, speed: 1.4, course: 90,
                       courseAccuracy: 60),
        // the user may have turned since
        LocationSample(coordinate: start, horizontalAccuracy: 5, timestamp: now.addingTimeInterval(-5), speed: 1.4,
                       course: 90),
    ])
    func withoutAWalkingCourseTheMapSaysOnlyHowFar(_ fix: LocationSample) async {
        let session = await makeSession(fixes: [fix], walked: 20, reports: CapturingReports())

        session.showOnMap(mapReports())

        #expect(session.mapAccessibilityLabel.hasSuffix("construction, 50 metres away."))
    }
}
