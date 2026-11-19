import Foundation
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

    nonisolated func observations() -> AsyncStream<SceneObservation> { AsyncStream { $0.finish() } }
    nonisolated func geoTrackingUpdates() -> AsyncStream<GeoTrackingUpdate> { AsyncStream { $0.finish() } }

    func start() async throws { calls.append("start") }
    func stop() async { calls.append("stop") }
    func setGeoTrackingWanted(_ wanted: Bool) async { calls.append(wanted ? "geo" : "no geo") }
}

struct TripCameraCoordinatorTests {
    private func calls(for phases: [TripPhase], scene: RecordingScene = RecordingScene()) async -> [String] {
        await TripCameraCoordinator(trip: ScriptedTrip(phases: phases), scene: scene).run()
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
        let scene = GeoScene()
        await TripCameraCoordinator(trip: ScriptedTrip(phases: [.active, .paused, .active]), scene: scene).run()

        #expect(await scene.calls == ["geo", "start", "stop", "no geo", "geo", "start", "stop", "no geo"])
    }

    @Test
    func aFailedStartIsNotBalancedWithAStop() async {
        let calls = await calls(for: [.active, .planning], scene: RecordingScene(startFails: true))
        #expect(calls == ["start"])
    }
}
