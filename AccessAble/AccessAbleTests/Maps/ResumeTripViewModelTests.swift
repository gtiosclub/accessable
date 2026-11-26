import Foundation
import Testing
@testable import AccessAble

/// A trip that stays in planning and keeps what each `startTrip` was given.
private final class StartRecordingTrip: TripStateProviding, Sendable {
    /// One element per `startTrip`, so a test can wait for it without a clock.
    let starts: AsyncStream<Start>
    private let started: AsyncStream<Start>.Continuation

    struct Start: Sendable {
        var route: NavigationRoute
        var destination: Destination
        var resumingAtStep: Int?
    }

    init() {
        (starts, started) = AsyncStream.makeStream()
    }

    func tripStates() -> AsyncStream<TripState> {
        AsyncStream { continuation in
            continuation.yield(.idle)
            continuation.finish()
        }
    }

    func tripRoutes() -> AsyncStream<NavigationRoute?> { AsyncStream { $0.finish() } }

    func startTrip(route: NavigationRoute, destination: Destination, resumingAtStep: Int?) async {
        started.yield(Start(route: route, destination: destination, resumingAtStep: resumingAtStep))
    }

    func pauseTrip() async {}
    func resumeTrip() async {}
    func endTrip() async {}
    func reroute() async {}
    func reportQuestionEnded(_ reportID: String, outcome: ReportQuestionOutcome) async {}
}

/// A store in a temporary directory, on a clock the test sets.
private final class ResumeHarness: Sendable {
    let directory = FileManager.default.temporaryDirectory.appending(path: "ResumeTripViewModelTests-\(UUID())")
    let time = ManualDate()
    let store: SavedTripStore
    /// Starts where `PlaceholderLocationProvider`'s fix is, so starting doesn't ask for a fresh route; slower than
    /// `MapsSamples.route`, so the test can tell the two apart.
    let route = try! NavigationRoute(coordinates: MapsSamples.route.coordinates, steps: MapsSamples.route.steps,
                                     estimatedDuration: 500)

    init() {
        store = SavedTripStore(directory: directory, now: { [time] in time.now })
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var fileExists: Bool { FileManager.default.fileExists(atPath: store.url.path()) }

    @discardableResult
    func saveTrip(source: RouteSource = .valhalla) -> SavedTrip {
        let now = time.now
        let trip = SavedTrip(tripID: UUID(), route: route, routeSource: source, destination: MapsSamples.destination,
                             passedStepCount: 1, startedAt: now.addingTimeInterval(-300), savedAt: now)
        store.save(trip)
        return trip
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ResumeTripViewModelTests {
    @Test
    func offersARecentSavedTrip() async {
        let harness = ResumeHarness()
        let trip = harness.saveTrip()
        harness.time.advance(by: SavedTripStore.maximumAge - 1)
        let model = ResumeTripViewModel(store: harness.store, trip: PlaceholderTripProvider())
        await model.check()

        #expect(model.offer == trip)
        #expect(model.title == "Resume your trip to Sample entrance?")
    }

    @Test
    func offersNothingWithoutASavedTrip() async {
        let harness = ResumeHarness()
        let model = ResumeTripViewModel(store: harness.store, trip: PlaceholderTripProvider())
        await model.check()

        #expect(model.offer == nil)
    }

    @Test
    func offersNothingForATripTwoHoursOld() async {
        let harness = ResumeHarness()
        harness.saveTrip()
        harness.time.advance(by: SavedTripStore.maximumAge)
        let model = ResumeTripViewModel(store: harness.store, trip: PlaceholderTripProvider())
        await model.check()

        #expect(model.offer == nil)
        #expect(!harness.fileExists)
    }

    @Test
    func offersNothingWhileATripIsRunning() async {
        let harness = ResumeHarness()
        harness.saveTrip()
        let model = ResumeTripViewModel(store: harness.store,
                                        trip: PreviewTripProvider(state: TripState(phase: .active)))
        await model.check()

        #expect(model.offer == nil)
        #expect(harness.store.load() != nil)
    }

    @Test
    func noThanksDeletesTheSavedTrip() async {
        let harness = ResumeHarness()
        harness.saveTrip()
        let model = ResumeTripViewModel(store: harness.store, trip: PlaceholderTripProvider())
        await model.check()
        model.decline()

        #expect(model.offer == nil)
        #expect(harness.store.load() == nil)
        #expect(!harness.fileExists)
    }

    @Test
    func aResumedBackupRouteIsStillOne() async throws {
        let harness = ResumeHarness()
        harness.saveTrip(source: .appleMaps)
        let model = ResumeTripViewModel(store: harness.store, trip: PlaceholderTripProvider())
        await model.check()
        let plan = try #require(model.resume())

        #expect(plan.plannedRoute?.route.source == .appleMaps)
    }

    @Test
    func resumingStartsTheTripOnTheSavedRoute() async throws {
        let harness = ResumeHarness()
        let saved = harness.saveTrip()
        // two hours on, the route is far older than a start would take without asking for a fresh one
        harness.time.advance(by: SavedTripStore.maximumAge - 1)
        let model = ResumeTripViewModel(store: harness.store, trip: PlaceholderTripProvider(),
                                        now: { [time = harness.time] in time.now })
        await model.check()
        let plan = try #require(model.resume())
        #expect(model.offer == nil)
        #expect(plan.place.name == "Sample entrance")

        let trip = StartRecordingTrip()
        var services = AppServices.preview
        services.trip = trip
        services.scene = PlaceholderSceneProvider()
        services.location = PlaceholderLocationProvider()
        let session = TripSessionViewModel(plan: plan, services: services,
                                           now: { [time = harness.time] in time.now })
        let running = Task { await session.run() }
        var starts = trip.starts.makeAsyncIterator()
        let start = try #require(await starts.next())
        running.cancel()
        await running.value

        #expect(start.route == saved.route)
        #expect(start.destination == saved.destination)
        #expect(start.resumingAtStep == saved.passedStepCount)
    }
}
