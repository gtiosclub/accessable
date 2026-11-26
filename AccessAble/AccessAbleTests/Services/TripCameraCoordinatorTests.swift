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
    func reportQuestionEnded(_ reportID: String, outcome: ReportQuestionOutcome) async {}
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
    private let startFails: Bool

    init(startFails: Bool = false) { self.startFails = startFails }

    nonisolated func observations() -> AsyncStream<SceneObservation> { AsyncStream { $0.finish() } }
    nonisolated func geoTrackingUpdates() -> AsyncStream<GeoTrackingUpdate> { AsyncStream { $0.finish() } }

    func start() async throws {
        calls.append("start")
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

/// The trip screen's camera, opened and closed as `TripSessionViewModel.run()` does around the trip.
@MainActor
struct TripScreenCameraTests {
    private let plan = TripPlan(place: SampleContent.places[0], route: nil, isRecording: false)

    private func camera(_ scene: GeoScene, isGeoTrackingAvailableHere: @escaping @Sendable () async -> Bool) -> TripCamera {
        TripCamera(scene: scene, geoTracking: scene, isGeoTrackingAvailableHere: isGeoTrackingAvailableHere)
    }

    @Test
    func theTripScreenAsksForGeoTrackingBeforeItStartsTheCamera() async {
        let scene = GeoScene()
        let camera = camera(scene) { true }
        let session = TripSessionViewModel(plan: plan)

        await session.openCamera(camera)
        await session.closeCamera(camera)

        #expect(await scene.calls == ["geo", "start", "stop", "no geo"])
    }

    @Test
    func theTripScreenAsksAboutGeoTrackingOncePerTrip() async {
        let scene = GeoScene()
        let availability = AvailabilityCheck(available: true)
        let camera = camera(scene, isGeoTrackingAvailableHere: availability.check)
        let session = TripSessionViewModel(plan: plan)

        await session.openCamera(camera)
        await session.closeCamera(camera)
        await session.openCamera(camera)
        await session.closeCamera(camera)

        #expect(availability.timesAsked == 1)
        #expect(await scene.calls == ["geo", "start", "stop", "no geo", "geo", "start", "stop", "no geo"])
    }

    @Test(.timeLimit(.minutes(1)))
    func closingTheScreenWhileAskingNeverStartsTheCamera() async throws {
        let scene = GeoScene()
        let clock = ManualClock()
        let camera = camera(scene) { await ARSessionManager.isGeoTrackingAvailableHere(clock: clock, check: { _ in }) }
        let session = TripSessionViewModel(plan: plan)

        let opening = Task { await session.openCamera(camera) }
        try await clock.waitForSleepers(1)
        opening.cancel()
        await opening.value
        await session.closeCamera(camera)

        #expect(await scene.calls.isEmpty)
        #expect(!session.isCameraReady)
    }

    // the camera view takes its own hold, so it must not start the session before the geo ask
    @Test(.timeLimit(.minutes(1)))
    func theCameraPictureWaitsUntilGeoTrackingWasAskedFor() async throws {
        let scene = GeoScene()
        let clock = ManualClock()
        let camera = camera(scene) { await ARSessionManager.isGeoTrackingAvailableHere(clock: clock, check: { _ in }) }
        let session = TripSessionViewModel(plan: plan)

        let opening = Task { await session.openCamera(camera) }
        try await clock.waitForSleepers(1)
        #expect(!session.isCameraReady)
        clock.advance(by: .seconds(10))
        await opening.value

        #expect(session.isCameraReady)
        await session.closeCamera(camera)
        #expect(!session.isCameraReady)
    }

    @Test
    func theCameraPictureFollowsTheGeoAskAndStart() async {
        let scene = GeoScene()
        let camera = camera(scene) { true }
        let session = TripSessionViewModel(plan: plan)

        await session.openCamera(camera)

        #expect(session.isCameraReady)
        #expect(await scene.calls == ["geo", "start"])
        await session.closeCamera(camera)
    }

    @Test
    func aFailedStartStillShowsTheCameraViewForItsError() async {
        let camera = camera(GeoScene(startFails: true)) { true }
        let session = TripSessionViewModel(plan: plan)

        await session.openCamera(camera)

        #expect(session.isCameraReady)
    }
}
