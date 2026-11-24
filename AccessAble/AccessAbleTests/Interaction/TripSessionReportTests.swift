import Foundation
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
}

/// Keeps every report submitted; a failing one throws instead.
private actor CapturingReports: ReportService {
    struct Offline: Error {}

    let fails: Bool
    private(set) var submitted: [Report] = []

    init(fails: Bool = false) {
        self.fails = fails
    }

    func submit(_ report: Report) async throws {
        if fails { throw Offline() }
        submitted.append(report)
    }

    func reports(near coordinate: GeoCoordinate, radius: Double) async throws -> [Report] { submitted }
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
    let state: TripState

    func tripStates() -> AsyncStream<TripState> {
        AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    func tripRoutes() -> AsyncStream<NavigationRoute?> { AsyncStream { $0.finish() } }
    func startTrip(route: NavigationRoute, destination: Destination) async {}
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

    /// A trip on `route` that has had `fixes`, `walked` metres along when given.
    private func makeSession(
        fixes: [LocationSample] = [preciseFix],
        walked: Double? = nil,
        reports: CapturingReports,
        signedIn: Bool = true,
        reportsAvailable: Bool = true
    ) async -> TripSessionViewModel {
        var services = AppServices.preview
        services.announcements = announcements
        services.commands = commands
        services.sceneDescriber = SilentScene()
        services.auth = PlaceholderAuthService(signedIn: signedIn)
        services.reports = reports
        services.reportsAvailable = reportsAvailable
        services.location = ScriptedLocation(samples: fixes)
        services.trip = FixedTrip(state: walked.map {
            TripState(phase: .active, distanceRemaining: route.totalDistance - $0)
        } ?? .idle)
        let session = TripSessionViewModel(
            plan: TripPlan(place: SampleContent.places[0], route: nil, isRecording: false),
            services: services,
            now: { now }
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
        let session = await makeSession(reports: CapturingReports(fails: true))

        await session.submitReport(kind: .construction)

        #expect(await announcements.said == ["I couldn't send that report. Check your connection and try again."])
    }

    /// Without a real report service (REPORT-3), nothing is stored and the user is told.
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
}
