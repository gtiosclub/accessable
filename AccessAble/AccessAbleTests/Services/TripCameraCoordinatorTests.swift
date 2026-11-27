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
    func startTrip(route: NavigationRoute, destination: Destination, preferences: RoutePreferences,
                   resumingAtStep: Int?) async {}
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
    /// Background availability checks started, kept out of `calls` since they don't touch the camera.
    private(set) var timesPrepared = 0
    /// How often the known answer was asked for.
    private(set) var timesAsked = 0
    private let startFails: Bool
    private var known: Bool?
    /// Apple's answer, in once a background check has been started.
    private let answer: Bool?

    init(startFails: Bool = false, known: Bool? = nil, answer: Bool? = nil) {
        self.startFails = startFails
        self.known = known
        self.answer = answer
    }

    nonisolated func observations() -> AsyncStream<SceneObservation> { AsyncStream { $0.finish() } }
    nonisolated func geoTrackingUpdates() -> AsyncStream<GeoTrackingUpdate> { AsyncStream { $0.finish() } }

    func start() async throws {
        calls.append("start")
        if startFails { throw RecordingScene.Unavailable() }
    }

    func stop() async { calls.append("stop") }

    func prepareGeoTracking() async {
        timesPrepared += 1
        if known == nil { known = answer }
    }

    func knownGeoAvailability() async -> Bool? {
        timesAsked += 1
        return known
    }

    func setGeoTrackingWanted(_ wanted: Bool) async { calls.append(wanted ? "geo" : "no geo") }
}

struct TripCameraCoordinatorTests {
    private func calls(for phases: [TripPhase], scene: RecordingScene = RecordingScene()) async -> [String] {
        let camera = TripCamera(scene: scene, geoTracking: nil)
        await TripCameraCoordinator(trip: ScriptedTrip(phases: phases), camera: camera).run()
        return await scene.calls
    }

    private func run(_ phases: [TripPhase], scene: GeoScene) async -> [String] {
        let camera = TripCamera(scene: scene, geoTracking: scene)
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
        let calls = await run([.active, .paused, .active], scene: GeoScene(known: true))

        #expect(calls == ["geo", "start", "stop", "no geo", "geo", "start", "stop", "no geo"])
    }

    @Test
    func availabilityIsAskedOncePerTrip() async {
        let scene = GeoScene(known: true)
        _ = await run([.active, .paused, .active, .paused, .active], scene: scene)
        #expect(await scene.timesAsked == 1)

        let twoTrips = GeoScene(known: true)
        _ = await run([.active, .arrived, .planning, .active], scene: twoTrips)
        #expect(await twoTrips.timesAsked == 2)
    }

    @Test
    func noGeoTrackingWhereItIsUnavailable() async {
        let calls = await run([.active, .planning], scene: GeoScene(known: false))
        #expect(calls == ["start", "stop"])
    }

    // Apple's "no" holds for the trip: resuming doesn't ask again
    @Test
    func aRealNoIsKeptForTheTrip() async {
        let scene = GeoScene(known: false)
        let calls = await run([.active, .paused, .active], scene: scene)

        #expect(calls == ["start", "stop", "start", "stop"])
        #expect(await scene.timesAsked == 1)
    }

    @Test
    func anUnknownAnswerStartsWorldTrackingAndAsksApple() async {
        let scene = GeoScene()
        let calls = await run([.active], scene: scene)

        #expect(calls == ["start", "stop"])
        #expect(await scene.timesPrepared == 1)
    }

    // "not known yet" isn't kept as "no", so the answer found meanwhile is used at the next start
    @Test(arguments: [[TripPhase.active, .paused, .active], [.active, .arrived, .planning, .active]])
    func anUnknownAnswerIsAskedAgainAtTheNextStart(phases: [TripPhase]) async {
        let calls = await run(phases, scene: GeoScene(answer: true))

        #expect(calls == ["start", "stop", "geo", "start", "stop", "no geo"])
    }

    @Test
    func aFailedStartGivesGeoTrackingBack() async {
        let calls = await run([.active, .planning], scene: GeoScene(startFails: true, known: true))
        #expect(calls == ["geo", "start", "no geo"])
    }

    @Test
    func betweenTripsItAsksAppleAheadOfTime() async {
        let scene = GeoScene(known: true)
        _ = await run([.planning, .active, .arrived, .planning], scene: scene)

        #expect(await scene.timesPrepared == 2)
    }

    // the answer found ahead of time is used as it is, so no check is started at the camera
    @Test(arguments: [true, false])
    func aKnownAnswerSkipsTheWait(known: Bool) async {
        let scene = GeoScene(known: known)
        let calls = await run([.active], scene: scene)

        #expect(await scene.timesPrepared == 0)
        #expect(calls == (known ? ["geo", "start", "stop", "no geo"] : ["start", "stop"]))
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

    private func camera(_ scene: GeoScene) -> TripCamera {
        TripCamera(scene: scene, geoTracking: scene)
    }

    @Test
    func theTripScreenAsksForGeoTrackingBeforeItStartsTheCamera() async {
        let scene = GeoScene(known: true)
        let camera = camera(scene)
        let session = TripSessionViewModel(plan: plan)

        await session.openCamera(camera)
        await session.closeCamera(camera)

        #expect(await scene.calls == ["geo", "start", "stop", "no geo"])
    }

    @Test
    func theTripScreenAsksAboutGeoTrackingOncePerTrip() async {
        let scene = GeoScene(known: true)
        let camera = camera(scene)
        let session = TripSessionViewModel(plan: plan)

        await session.openCamera(camera)
        await session.closeCamera(camera)
        await session.openCamera(camera)
        await session.closeCamera(camera)

        #expect(await scene.timesAsked == 1)
        #expect(await scene.calls == ["geo", "start", "stop", "no geo", "geo", "start", "stop", "no geo"])
    }

    // the screen coming back uses the answer found while it was away
    @Test
    func theTripScreenAsksAgainWhileTheAnswerIsUnknown() async {
        let scene = GeoScene(answer: true)
        let camera = camera(scene)
        let session = TripSessionViewModel(plan: plan)

        await session.openCamera(camera)
        await session.closeCamera(camera)
        await session.openCamera(camera)
        await session.closeCamera(camera)

        #expect(await scene.timesPrepared == 1)
        #expect(await scene.calls == ["start", "stop", "geo", "start", "stop", "no geo"])
    }

    @Test
    func closingTheScreenWhileAskingNeverStartsTheCamera() async {
        let scene = GeoScene(known: true)
        let camera = camera(scene)
        let session = TripSessionViewModel(plan: plan)

        // on the main actor, so it can't start before it is cancelled
        let opening = Task { await session.openCamera(camera) }
        opening.cancel()
        await opening.value
        await session.closeCamera(camera)

        #expect(await scene.calls.isEmpty)
        #expect(!session.isCameraReady)
    }

    // the camera view takes its own hold, so it shows only once the session has started on world tracking
    @Test
    func theCameraPictureShowsAtOnceWhileTheAnswerIsUnknown() async {
        let scene = GeoScene()
        let camera = camera(scene)
        let session = TripSessionViewModel(plan: plan)
        #expect(!session.isCameraReady)

        await session.openCamera(camera)

        #expect(session.isCameraReady)
        #expect(await scene.calls == ["start"])
        await session.closeCamera(camera)
        #expect(!session.isCameraReady)
    }

    @Test
    func theCameraPictureFollowsTheGeoAskAndStart() async {
        let scene = GeoScene(known: true)
        let camera = camera(scene)
        let session = TripSessionViewModel(plan: plan)

        await session.openCamera(camera)

        #expect(session.isCameraReady)
        #expect(await scene.calls == ["geo", "start"])
        await session.closeCamera(camera)
    }

    @Test
    func aFailedStartStillShowsTheCameraViewForItsError() async {
        let camera = camera(GeoScene(startFails: true, known: true))
        let session = TripSessionViewModel(plan: plan)

        await session.openCamera(camera)

        #expect(session.isCameraReady)
    }
}
