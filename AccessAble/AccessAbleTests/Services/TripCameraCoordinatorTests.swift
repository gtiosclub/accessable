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
    func startTrip(route: NavigationRoute, destination: Destination, preferences: RoutePreferences,
                   resumingAtStep: Int?) async {}
    func pauseTrip() async {}
    func resumeTrip() async {}
    func endTrip() async {}
    func reroute() async {}
    func reportQuestionEnded(_ reportID: String, outcome: ReportQuestionOutcome) async {}
}

/// A trip the test moves phase by phase.
private struct SteppedTrip: TripStateProviding {
    private let states: AsyncStream<TripState>
    private let continuation: AsyncStream<TripState>.Continuation

    init() {
        (states, continuation) = AsyncStream.makeStream()
    }

    func go(_ phase: TripPhase) { send(TripState(phase: phase, updatedAt: .now)) }
    func send(_ state: TripState) { continuation.yield(state) }
    func finish() { continuation.finish() }

    func tripStates() -> AsyncStream<TripState> { states }
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

/// A geo-tracking camera whose updates the test sends one by one, waiting until the trip has taken each in.
private final class SteppedGeoScene: SceneObservationProviding, GeoTrackingProviding, Sendable {
    private enum Condition { case takenIn, watcherGone }
    private typealias Waiter = (condition: Condition, continuation: CheckedContinuation<Void, any Error>)

    private struct State {
        var pending: [GeoTrackingUpdate] = []
        /// The trip's watcher, waiting for the next update.
        var reader: (id: UUID, continuation: CheckedContinuation<GeoTrackingUpdate?, Never>)?
        var isWatched = false
        var timesWatched = 0
        /// Reads and waits cancelled before they started waiting.
        var cancelled: Set<UUID> = []
        var waiters: [UUID: Waiter] = [:]

        func holds(_ condition: Condition) -> Bool {
            switch condition {
            case .takenIn: reader != nil && pending.isEmpty
            case .watcherGone: !isWatched
            }
        }

        mutating func takeSatisfiedWaiters() -> [CheckedContinuation<Void, any Error>] {
            let satisfied = waiters.filter { holds($0.value.condition) }
            for id in satisfied.keys { waiters.removeValue(forKey: id) }
            return satisfied.values.map(\.continuation)
        }
    }

    private let state = Mutex(State())
    private let available: Bool

    init(available: Bool = true) { self.available = available }

    /// How often the trip started watching geo updates.
    var timesWatched: Int { state.withLock { $0.timesWatched } }

    func send(_ update: GeoTrackingUpdate) {
        let reader = state.withLock { state in
            guard let reader = state.reader else {
                state.pending.append(update)
                return CheckedContinuation<GeoTrackingUpdate?, Never>?.none
            }
            state.reader = nil
            return reader.continuation
        }
        reader?.resume(returning: update)
    }

    /// Returns once the trip has taken in every update sent and waits for the next.
    func waitUntilTakenIn() async throws { try await wait(until: .takenIn) }

    /// Returns once the trip has stopped watching geo updates.
    func waitUntilUnwatched() async throws { try await wait(until: .watcherGone) }

    private func wait(until condition: Condition) async throws {
        let id = UUID()
        defer { state.withLock { _ = $0.cancelled.remove(id) } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Start { case cancelled, ready, waiting }
                let start = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return Start.cancelled }
                    if state.holds(condition) { return .ready }
                    state.waiters[id] = (condition, continuation)
                    return .waiting
                }
                switch start {
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .ready: continuation.resume()
                case .waiting: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                guard let waiter = state.waiters.removeValue(forKey: id) else {
                    state.cancelled.insert(id)
                    return Waiter?.none
                }
                return waiter
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// The watcher's next update; nil once it is cancelled.
    private func nextUpdate() async -> GeoTrackingUpdate? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<GeoTrackingUpdate?, Never>) in
                enum Start { case cancelled, update(GeoTrackingUpdate), waiting }
                let (start, satisfied) = state.withLock { state in
                    let start: Start
                    if state.cancelled.remove(id) != nil {
                        state.isWatched = false
                        start = .cancelled
                    } else if !state.pending.isEmpty {
                        start = .update(state.pending.removeFirst())
                    } else {
                        state.reader = (id, continuation)
                        start = .waiting
                    }
                    return (start, state.takeSatisfiedWaiters())
                }
                for waiter in satisfied { waiter.resume() }
                switch start {
                case .cancelled: continuation.resume(returning: nil)
                case let .update(update): continuation.resume(returning: update)
                case .waiting: break
                }
            }
        } onCancel: {
            let (reader, satisfied) = state.withLock { state in
                guard let reader = state.reader, reader.id == id else {
                    state.cancelled.insert(id)
                    return (CheckedContinuation<GeoTrackingUpdate?, Never>?.none, [CheckedContinuation<Void, any Error>]())
                }
                state.reader = nil
                state.isWatched = false
                return (reader.continuation, state.takeSatisfiedWaiters())
            }
            reader?.resume(returning: nil)
            for waiter in satisfied { waiter.resume() }
        }
    }

    // MARK: - SceneObservationProviding

    func observations() -> AsyncStream<SceneObservation> { AsyncStream { $0.finish() } }
    func start() async throws {}
    func stop() async {}

    // MARK: - GeoTrackingProviding

    func prepareGeoTracking() async {}
    func knownGeoAvailability() async -> Bool? { available }
    func setGeoTrackingWanted(_ wanted: Bool) async {}

    func geoTrackingUpdates() -> AsyncStream<GeoTrackingUpdate> {
        state.withLock { state in
            state.isWatched = true
            state.timesWatched += 1
        }
        return AsyncStream(unfolding: { [self] in await nextUpdate() })
    }
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

/// Guidance that stops mid-trip is restarted with the map showing, where no camera screen exists.
@MainActor
struct TripGuidanceRecoveryTests {
    private let guidance = FakeGuidance()
    private let sink = RecordingSink()
    private let recovery = GuidanceRecovery()
    private let trip = SteppedTrip()

    private func startRunning() -> Task<Void, Never> {
        let coordinator = TripCameraCoordinator(
            trip: trip, camera: TripCamera(scene: guidance, geoTracking: nil),
            recovery: recovery, announcements: sink
        )
        return Task { await coordinator.run() }
    }

    @Test(.timeLimit(.minutes(1)))
    func aStopMidTripIsRestartedOnce() async throws {
        let running = startRunning()
        trip.go(.active)
        try await guidance.waitForSubscribers(1)

        guidance.send(.stopped(reason: "Tracking could not be recovered."))
        guidance.send(.running)
        await sink.waitFor("guidance-restored")
        trip.go(.arrived)
        trip.finish()
        await running.value

        #expect(guidance.restartCount == 1)
        #expect(sink.keys == ["guidance-stopped", "guidance-restored"])
        #expect(guidance.calls == ["start", "stop"])
    }

    @Test(.timeLimit(.minutes(1)))
    func withTheCameraScreenOpenTooItIsStillRestartedOnce() async throws {
        let running = startRunning()
        trip.go(.active)
        try await guidance.waitForSubscribers(1)
        let screen = GuidanceStatusMonitor(recovery: recovery, announcements: sink)
        screen.watch(guidance)
        // the screen's own subscription, for keeping the display awake
        try await guidance.waitForSubscribers(2)

        guidance.send(.stopped(reason: "Tracking could not be recovered."))
        guidance.send(.running)
        await sink.waitFor("guidance-restored")
        screen.stop()
        trip.go(.arrived)
        trip.finish()
        await running.value

        #expect(guidance.restartCount == 1)
        #expect(sink.keys == ["guidance-stopped", "guidance-restored"])
    }

    // leaving the camera screen mid-trip, for the map, keeps the trip's recovery
    @Test(.timeLimit(.minutes(1)))
    func closingTheCameraScreenLeavesTheTripsRestart() async throws {
        let running = startRunning()
        trip.go(.active)
        try await guidance.waitForSubscribers(1)
        let screen = GuidanceStatusMonitor(recovery: recovery, announcements: sink)
        screen.watch(guidance)
        try await guidance.waitForSubscribers(2)
        screen.stop()
        try await guidance.waitForSubscribers(1)

        guidance.send(.stopped(reason: "Tracking could not be recovered."))
        for await _ in guidance.restarts { break }
        trip.finish()
        await running.value

        #expect(guidance.restartCount == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [TripPhase.paused, .arrived, .planning])
    func afterTheTripLetsGoAStopDoesNothing(phase: TripPhase) async throws {
        let running = startRunning()
        trip.go(.active)
        try await guidance.waitForSubscribers(1)
        trip.go(phase)
        try await guidance.waitForSubscribers(0)

        guidance.send(.stopped(reason: "Tracking could not be recovered."))
        trip.finish()
        await running.value

        #expect(guidance.restartCount == 0)
        #expect(sink.keys.isEmpty)
        #expect(guidance.calls == ["start", "stop"])
    }

    @Test(.timeLimit(.minutes(1)))
    func theRecoveryIsLetGoWhenTheTripStreamEnds() async throws {
        let running = startRunning()
        trip.go(.active)
        try await guidance.waitForSubscribers(1)
        trip.finish()
        await running.value

        try await guidance.waitForSubscribers(0)
        #expect(guidance.calls == ["start", "stop"])
    }
}

/// Settings → Phone Aiming Help, switched by the test mid-trip.
private final class AimingHelpSetting: Sendable {
    private let value = Mutex(true)

    var isOn: Bool {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// The AR-5 hold-up prompt, given while the trip holds the camera with geo-tracking.
@MainActor
struct TripAimingHelpTests {
    private let geo = SteppedGeoScene()
    private let sink = RecordingSink()
    private let trip = SteppedTrip()
    private let date = ManualDate()
    private let aimingHelp = AimingHelpSetting()

    private static let unlocked = GeoTrackingUpdate(
        state: .localizing, accuracy: .undetermined, timestamp: .now, stateReason: .visualLocalizationFailed
    )
    private static let locked = GeoTrackingUpdate(state: .localized, accuracy: .high, timestamp: .now, stateReason: nil)

    private func startRunning(_ scene: SteppedGeoScene? = nil) -> Task<Void, Never> {
        let scene = scene ?? geo
        let aimingHelp = aimingHelp
        let date = date
        let coordinator = TripCameraCoordinator(
            trip: trip, camera: TripCamera(scene: scene, geoTracking: scene), announcements: sink,
            phoneAimingHelp: { aimingHelp.isOn }, now: { date.now }
        )
        return Task { await coordinator.run() }
    }

    private func state(_ phase: TripPhase = .active, turnIn distance: Double) -> TripState {
        TripState(
            phase: phase,
            nextManeuver: Maneuver(kind: .turnRight, instruction: "Turn right",
                                   coordinate: GeoCoordinate(latitude: 33.77, longitude: -84.39)),
            distanceToNextManeuver: distance
        )
    }

    /// Walks up to a turn: the update that brings it, then the next.
    private func reachTurn() {
        trip.send(state(turnIn: 120))
        trip.send(state(turnIn: 35))
        trip.send(state(turnIn: 30))
    }

    private func send(_ update: GeoTrackingUpdate) async throws {
        geo.send(update)
        try await geo.waitUntilTakenIn()
    }

    private func finish(_ running: Task<Void, Never>) async {
        trip.finish()
        await running.value
    }

    private var prompts: Int { sink.keys.filter { $0 == GeoAimingCoach.dedupKey }.count }

    @Test(.timeLimit(.minutes(1)))
    func aTurnWithoutALockIsPromptedThroughTheAnnouncements() async throws {
        let running = startRunning()
        trip.send(state(turnIn: 120))
        try await send(Self.unlocked)
        reachTurn()
        await sink.waitFor(GeoAimingCoach.dedupKey)
        await finish(running)

        #expect(sink.keys == [GeoAimingCoach.dedupKey])
    }

    // the trip says the turn cue after publishing the update that brought the turn, and the prompt waits for the next
    @Test(.timeLimit(.minutes(1)))
    func thePromptFollowsTheTurnCue() async throws {
        let running = startRunning()
        trip.send(state(turnIn: 120))
        try await send(Self.unlocked)
        trip.send(state(turnIn: 35))
        await sink.submit(AnnouncementEvent(category: .maneuver, priority: .normal, text: "In 35 metres, turn right.",
                                            source: .navigation, dedupKey: "step-1-prepare"))
        trip.send(state(turnIn: 30))
        await sink.waitFor(GeoAimingCoach.dedupKey)
        await finish(running)

        #expect(sink.keys == ["step-1-prepare", GeoAimingCoach.dedupKey])
    }

    @Test(.timeLimit(.minutes(1)))
    func noGeoUpdateYetMeansNoPrompt() async throws {
        let running = startRunning()
        trip.send(state(turnIn: 120))
        try await geo.waitUntilTakenIn()
        reachTurn()
        await finish(running)

        #expect(sink.keys.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aLockLostBeforeTheTurnIsPrompted() async throws {
        let running = startRunning()
        trip.send(state(turnIn: 120))
        try await send(Self.locked)
        reachTurn()
        try await send(Self.unlocked)
        trip.send(state(turnIn: 20))
        await sink.waitFor(GeoAimingCoach.dedupKey)
        await finish(running)

        #expect(sink.keys == [GeoAimingCoach.dedupKey])
    }

    @Test(.timeLimit(.minutes(1)))
    func theSettingIsReadOnEveryUpdate() async throws {
        let running = startRunning()
        trip.send(state(turnIn: 120))
        try await send(Self.unlocked)
        aimingHelp.isOn = false
        reachTurn()
        date.advance(by: GeoAimingCoach.cooldown)
        aimingHelp.isOn = true
        reachTurn()
        await sink.waitFor(GeoAimingCoach.dedupKey)
        await finish(running)

        #expect(sink.keys == [GeoAimingCoach.dedupKey])
    }

    @Test(.timeLimit(.minutes(1)))
    func turningTheSettingOffMidTripSilencesIt() async throws {
        let running = startRunning()
        trip.send(state(turnIn: 120))
        try await send(Self.unlocked)
        reachTurn()
        await sink.waitFor(GeoAimingCoach.dedupKey)
        aimingHelp.isOn = false
        date.advance(by: GeoAimingCoach.cooldown)
        reachTurn()
        await finish(running)

        #expect(prompts == 1)
    }

    // the camera is let go and held again over a pause, and the cooldown carries over
    @Test(.timeLimit(.minutes(1)))
    func theCooldownOutlastsAPause() async throws {
        let running = startRunning()
        trip.send(state(turnIn: 120))
        try await send(Self.unlocked)
        reachTurn()
        await sink.waitFor(GeoAimingCoach.dedupKey)
        trip.send(state(.paused, turnIn: 30))
        try await geo.waitUntilUnwatched()
        date.advance(by: 60)
        trip.send(state(turnIn: 120))
        try await send(Self.unlocked)
        reachTurn()
        await finish(running)

        #expect(geo.timesWatched == 2)
        #expect(prompts == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [TripPhase.paused, .arrived, .planning])
    func leavingTheTripStopsWatching(phase: TripPhase) async throws {
        let running = startRunning()
        trip.send(state(turnIn: 120))
        try await send(Self.unlocked)
        trip.send(state(turnIn: 35))
        trip.send(state(phase, turnIn: 30))
        try await geo.waitUntilUnwatched()
        trip.send(state(phase, turnIn: 25))
        await finish(running)

        #expect(sink.keys.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func noGeoTrackingMeansNoPrompt() async {
        let scene = SteppedGeoScene(available: false)
        let running = startRunning(scene)
        reachTurn()
        await finish(running)

        #expect(scene.timesWatched == 0)
        #expect(sink.keys.isEmpty)
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
