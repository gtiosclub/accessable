import Foundation
import Synchronization
import Testing
@testable import AccessAble

private struct ScriptedTrip: TripStateProviding {
    let phases: [TripPhase]

    func tripStates() -> AsyncStream<TripState> {
        AsyncStream { continuation in
            for phase in phases { continuation.yield(TripState(phase: phase, updatedAt: .now)) }
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

private actor RecordingScene: SceneObservationProviding {
    struct Unavailable: Error {}

    private(set) var calls: [String] = []
    private let startFails: Bool

    init(startFails: Bool = false) { self.startFails = startFails }

    nonisolated func observations() -> AsyncStream<SceneObservation> { AsyncStream { $0.finish() } }

    func start() async throws {
        calls.append("start")
        if startFails { throw Unavailable() }
    }

    func stop() async { calls.append("stop") }
}

private actor GeoScene: SceneObservationProviding, GeoTrackingProviding {
    private(set) var calls: [String] = []
    /// One element per `start()`, so a test can wait for the camera without a clock.
    nonisolated let starts: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    private let startFails: Bool

    init(startFails: Bool = false) {
        self.startFails = startFails
        (starts, started) = AsyncStream.makeStream()
    }

    nonisolated func observations() -> AsyncStream<SceneObservation> { AsyncStream { $0.finish() } }
    nonisolated func geoTrackingUpdates() -> AsyncStream<GeoTrackingUpdate> { AsyncStream { $0.finish() } }

    func start() async throws {
        calls.append("start")
        started.yield()
        if startFails { throw RecordingScene.Unavailable() }
    }

    func stop() async { calls.append("stop") }
    func setGeoTrackingWanted(_ wanted: Bool) async { calls.append(wanted ? "geo" : "no geo") }
}

/// Answers whether geo-tracking is available here, counting how often it was asked.
private final class AvailabilityCheck: Sendable {
    private let available: Bool
    private let asked = Mutex(0)

    init(available: Bool) { self.available = available }

    var timesAsked: Int { asked.withLock { $0 } }

    func check() async -> Bool {
        asked.withLock { $0 += 1 }
        return available
    }
}

struct TripCameraCoordinatorTests {
    private func calls(for phases: [TripPhase], scene: RecordingScene = RecordingScene()) async -> [String] {
        let camera = TripCamera(scene: scene, geoTracking: nil, isGeoTrackingAvailableHere: { true })
        await TripCameraCoordinator(trip: ScriptedTrip(phases: phases), camera: camera).run()
        return await scene.calls
    }

    private func run(
        _ phases: [TripPhase], scene: GeoScene, availability: AvailabilityCheck = AvailabilityCheck(available: true)
    ) async -> [String] {
        let camera = TripCamera(scene: scene, geoTracking: scene, isGeoTrackingAvailableHere: availability.check)
        await TripCameraCoordinator(trip: ScriptedTrip(phases: phases), camera: camera).run()
        return await scene.calls
    }

    @Test
    func holdsTheCameraOnlyWhileActive() async {
        let calls = await calls(for: [.planning, .active, .active, .paused, .active, .arrived, .planning])
        #expect(calls == ["start", "stop", "start", "stop"])
    }

    @Test
    func noTripNeverTouchesTheCamera() async {
        #expect(await calls(for: [.planning, .planning]).isEmpty)
    }

    @Test
    func releasesTheCameraWhenTheStreamEndsMidTrip() async {
        #expect(await calls(for: [.active]) == ["start", "stop"])
    }

    @Test
    func tripsAskForGeoTrackingBeforeTheCameraStarts() async {
        let calls = await run([.active, .paused, .active], scene: GeoScene())

        #expect(calls == ["geo", "start", "stop", "no geo", "geo", "start", "stop", "no geo"])
    }

    @Test
    func availabilityIsAskedOncePerTrip() async {
        let availability = AvailabilityCheck(available: true)
        _ = await run([.active, .paused, .active, .paused, .active], scene: GeoScene(), availability: availability)
        #expect(availability.timesAsked == 1)

        let twoTrips = AvailabilityCheck(available: true)
        _ = await run([.active, .arrived, .planning, .active], scene: GeoScene(), availability: twoTrips)
        #expect(twoTrips.timesAsked == 2)
    }

    @Test
    func noGeoTrackingWhereItIsUnavailable() async {
        let calls = await run([.active, .planning], scene: GeoScene(), availability: AvailabilityCheck(available: false))
        #expect(calls == ["start", "stop"])
    }

    @Test
    func aFailedStartGivesGeoTrackingBack() async {
        let calls = await run([.active, .planning], scene: GeoScene(startFails: true))
        #expect(calls == ["geo", "start", "no geo"])
    }

    @Test
    func aFailedStartIsNotBalancedWithAStop() async {
        let calls = await calls(for: [.active, .planning], scene: RecordingScene(startFails: true))
        #expect(calls == ["start"])
    }
}

@MainActor
struct TripScreenCameraTests {
    @Test(.timeLimit(.minutes(1)))
    func theTripScreenAsksForGeoTrackingBeforeItStartsTheCamera() async {
        let scene = GeoScene()
        var services = AppServices.preview
        services.scene = scene
        services.geoTracking = scene
        services.isGeoTrackingAvailableHere = { true }
        services.location = PlaceholderLocationProvider()
        let session = TripSessionViewModel(
            plan: TripPlan(place: SampleContent.places[0], route: nil, isRecording: false), services: services
        )

        let running = Task { await session.run() }
        for await _ in scene.starts { break }
        running.cancel()
        await running.value

        #expect(await scene.calls == ["geo", "start", "stop", "no geo"])
    }
}
