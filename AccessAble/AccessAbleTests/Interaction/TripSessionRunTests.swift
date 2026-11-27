import Foundation
import Synchronization
import Testing
@testable import AccessAble

/// A trip that never leaves planning, as when starting it doesn't take: `startTrip` only counts.
private final class StuckTrip: TripStateProviding, Sendable {
    /// One element per `startTrip`, so a test can wait for it without a clock.
    let starts: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    private let count = Mutex(0)

    init() {
        (starts, started) = AsyncStream.makeStream()
    }

    var startCount: Int { count.withLock { $0 } }

    func tripStates() -> AsyncStream<TripState> {
        AsyncStream { continuation in
            continuation.yield(.idle)
            continuation.finish()
        }
    }

    func tripRoutes() -> AsyncStream<NavigationRoute?> { AsyncStream { $0.finish() } }

    func startTrip(route: NavigationRoute, destination: Destination, preferences: RoutePreferences,
                   resumingAtStep: Int?) async {
        count.withLock { $0 += 1 }
        started.yield()
    }

    func pauseTrip() async {}
    func resumeTrip() async {}
    func endTrip() async {}
    func reroute() async {}
    func reportQuestionEnded(_ reportID: String, outcome: ReportQuestionOutcome) async {}
}

private actor CountingScene: SceneObservationProviding {
    private(set) var calls: [String] = []

    nonisolated func observations() -> AsyncStream<SceneObservation> { AsyncStream { $0.finish() } }
    func start() async throws { calls.append("start") }
    func stop() async { calls.append("stop") }
}

@MainActor
struct TripSessionRunTests {
    /// A start that didn't take used to be retried at once, forever, on the main actor, so the
    /// task cancelling the screen never ran and the camera was never given back.
    @Test(.timeLimit(.minutes(1)))
    func closingTheScreenReturnsAndGivesTheCameraBack() async {
        let trip = StuckTrip()
        let scene = CountingScene()
        var services = AppServices.preview
        services.trip = trip
        services.scene = scene
        services.location = PlaceholderLocationProvider()
        let session = TripSessionViewModel(
            plan: TripPlan(place: SampleContent.places[0], route: nil, isRecording: false), services: services
        )

        let running = Task { await session.run() }
        for await _ in trip.starts { break }
        running.cancel()
        await running.value

        #expect(trip.startCount == 1)
        #expect(await scene.calls == ["start", "stop"])
    }
}
