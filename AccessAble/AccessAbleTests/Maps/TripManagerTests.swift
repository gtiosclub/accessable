import Foundation
import Synchronization
import Testing
@testable import AccessAble

// MARK: Fakes

/// A clock the test moves by hand; `sleep` returns when the clock passes its deadline.
private final class TestClock: Sendable {
    private struct Sleeper {
        let deadline: Date
        let seconds: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Date
        var sleepers: [UUID: Sleeper] = [:]
        var cancelled: Set<UUID> = []
        var woken: [TimeInterval] = []
    }

    private let state: Mutex<State>

    init(start: Date) {
        state = Mutex(State(now: start))
    }

    func now() -> Date {
        state.withLock { $0.now }
    }

    func sleep(_ duration: Duration) async throws {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let wasCancelled = state.withLock { state in
                    guard state.cancelled.remove(id) == nil else { return true }
                    state.sleepers[id] = Sleeper(deadline: state.now.addingTimeInterval(seconds), seconds: seconds,
                                                 continuation: continuation)
                    return false
                }
                if wasCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = state.withLock { state in
                guard let sleeper = state.sleepers.removeValue(forKey: id) else {
                    state.cancelled.insert(id)
                    return Sleeper?.none
                }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    /// Whether a sleep of about this length has been woken.
    func hasWoken(after seconds: TimeInterval) -> Bool {
        state.withLock { $0.woken.contains { abs($0 - seconds) < 0.01 } }
    }

    func advance(by seconds: TimeInterval) {
        let due = state.withLock { state in
            state.now = state.now.addingTimeInterval(seconds)
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }
            for id in due.keys { state.sleepers.removeValue(forKey: id) }
            state.woken += due.values.map(\.seconds)
            return due.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }
}

/// A fresh unbounded stream per subscriber, fed by the test, reporting when each one ends.
private final class ManualLocationProvider: LocationProvider, Sendable {
    private struct State {
        var streams: [AsyncStream<LocationSample>.Continuation] = []
        var terminated: Set<Int> = []
        var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    }

    private let state = Mutex(State())

    func locationSamples() -> AsyncStream<LocationSample> {
        let (stream, continuation) = AsyncStream.makeStream(of: LocationSample.self, bufferingPolicy: .unbounded)
        let index = state.withLock { state in
            state.streams.append(continuation)
            return state.streams.count - 1
        }
        continuation.onTermination = { [weak self] _ in self?.terminate(index) }
        return stream
    }

    func headingSamples() -> AsyncStream<HeadingSample> {
        AsyncStream { $0.finish() }
    }

    func authorizationStates() -> AsyncStream<LocationAuthorization> {
        AsyncStream { $0.finish() }
    }

    func requestAuthorization() async {}

    var streamCount: Int {
        state.withLock { $0.streams.count }
    }

    func yield(_ sample: LocationSample, toStream index: Int) {
        let continuation = state.withLock { $0.streams[index] }
        continuation.yield(sample)
    }

    func waitForTermination(ofStream index: Int) async {
        await withCheckedContinuation { continuation in
            let done = state.withLock { state in
                guard !state.terminated.contains(index) else { return true }
                state.waiters[index, default: []].append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    private func terminate(_ index: Int) {
        let waiters = state.withLock { state in
            state.terminated.insert(index)
            return state.waiters.removeValue(forKey: index) ?? []
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// Records submissions in order. Delivers each one at once unless `autoDelivers` is off, and can hold one
/// submission until released.
private actor RecordingEngine: AnnouncementEngineProtocol {
    private(set) var submitted: [AnnouncementEvent] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var autoDelivers = true
    private var holdsText: String?
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private nonisolated let delivered = Broadcaster<AnnouncementEvent>()

    func submit(_ event: AnnouncementEvent) async {
        submitted.append(event)
        let ready = countWaiters.filter { $0.count <= submitted.count }
        countWaiters.removeAll { $0.count <= submitted.count }
        ready.forEach { $0.continuation.resume() }
        if event.text == holdsText {
            holdsText = nil
            await withCheckedContinuation { continuation in
                held = continuation
                heldWaiters.forEach { $0.resume() }
                heldWaiters = []
            }
        }
        if autoDelivers { delivered.send(event) }
    }

    nonisolated func deliveredEvents() -> AsyncStream<AnnouncementEvent> {
        delivered.stream(bufferingPolicy: .unbounded)
    }

    func repeatLast() async {}
    func pause() async {}
    func resume() async {}
    func updateProfile(_ profile: GuidanceProfile) async {}

    func setAutoDelivers(_ value: Bool) {
        autoDelivers = value
    }

    @discardableResult
    func waitForCount(_ count: Int) async -> [AnnouncementEvent] {
        if submitted.count < count {
            await withCheckedContinuation { countWaiters.append((count, $0)) }
        }
        return submitted
    }

    /// Holds the next submission with this text inside `submit` until `release()`.
    func hold(text: String) {
        holdsText = text
    }

    func waitUntilHeld() async {
        guard held == nil else { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func release() {
        held?.resume()
        held = nil
    }

    var texts: [String] { submitted.map(\.text) }
}

/// Answers each request with the next scripted result. Successes wait for `respond()`, so the test controls when
/// the new route lands.
private actor ScriptedRouter: RoutingService {
    private var results: [Result<NavigationRoute, RoutingError>]
    private(set) var requests: [GeoCoordinate] = []
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var answered = 0

    init(_ results: [Result<NavigationRoute, RoutingError>]) {
        self.results = results
    }

    func route(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async throws -> NavigationRoute {
        requests.append(origin)
        let ready = requestWaiters.filter { $0.count <= requests.count }
        requestWaiters.removeAll { $0.count <= requests.count }
        ready.forEach { $0.continuation.resume() }
        let result = results.isEmpty ? .failure(.serverUnavailable) : results.removeFirst()
        if case .success = result {
            await withCheckedContinuation { pending.append($0) }
        }
        answered += 1
        return try result.get()
    }

    func respond() {
        pending.forEach { $0.resume() }
        pending = []
    }

    func waitForRequests(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }
}

/// The latest published state, with a way to wait for one that matches.
private actor StateRecorder {
    private var latest: TripState?
    private typealias Waiter = (
        predicate: @Sendable (TripState) -> Bool, continuation: CheckedContinuation<TripState, Never>
    )
    private var waiters: [Waiter] = []

    func record(_ state: TripState) {
        latest = state
        let ready = waiters.filter { $0.predicate(state) }
        waiters.removeAll { $0.predicate(state) }
        ready.forEach { $0.continuation.resume(returning: state) }
    }

    @discardableResult
    func waitFor(_ predicate: @escaping @Sendable (TripState) -> Bool) async -> TripState {
        if let latest, predicate(latest) { return latest }
        return await withCheckedContinuation { waiters.append((predicate, $0)) }
    }

    var current: TripState? { latest }
}

// MARK: Harness

/// Yields until `condition` holds, for effects that run after an await the test can't join.
private func waitUntil(_ condition: () async -> Bool) async {
    while await !condition() { await Task.yield() }
}

private let library = Destination(name: "Library", coordinate: GeoCoordinate(latitude: 33.7759, longitude: -84.3984))

/// North 100 m, right onto Ferst Drive, then 60 m east to the destination.
private func cornerRoute() throws -> NavigationRoute {
    let start = GeoCoordinate(latitude: 33.775, longitude: -84.399)
    let corner = TripWalk.destination(from: start, bearing: 0, distance: 100)
    let end = TripWalk.destination(from: corner, bearing: 90, distance: 60)
    func step(_ kind: ManeuverKind, _ index: Int, _ text: String) -> RouteStep {
        RouteStep(kind: kind, coordinateIndex: index, instruction: text, spokenInstruction: text)
    }
    return try NavigationRoute(coordinates: [start, corner, end], steps: [
        step(.depart, 0, "Walk north."),
        step(.turnRight, 1, "Turn right onto Ferst Drive."),
        step(.arrive, 2, "Your destination is on the left."),
    ], estimatedDuration: 130)
}

/// Where `Harness.goOffRoute(at: 49)` leaves the user, for a reroute answer that starts there.
private let harness0Origin = TripWalk.point(on: try! cornerRoute(), along: 49, lateral: -40)

/// A straight route east from `origin`, as a reroute answer.
private func eastRoute(from origin: GeoCoordinate) throws -> NavigationRoute {
    try NavigationRoute(coordinates: [origin, TripWalk.destination(from: origin, bearing: 90, distance: 80)], steps: [
        RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Head east.", spokenInstruction: "Head east."),
        RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "You have arrived."),
    ], estimatedDuration: 60)
}

private final class BackgroundRecorder: Sendable {
    private let calls = Mutex<[Bool]>([])

    func record(_ on: Bool) {
        calls.withLock { $0.append(on) }
    }

    var values: [Bool] { calls.withLock { $0 } }
}

private struct Harness {
    let clock = TestClock(start: TripWalk.start)
    let location = ManualLocationProvider()
    let engine = RecordingEngine()
    let router: ScriptedRouter
    let background = BackgroundRecorder()
    let states = StateRecorder()
    let manager: TripManager
    let route: NavigationRoute

    init(route: NavigationRoute? = nil, reroutes: [Result<NavigationRoute, RoutingError>] = []) throws {
        let route = try route ?? cornerRoute()
        self.route = route
        router = ScriptedRouter(reroutes)
        manager = TripManager(
            location: location, routing: router, announcements: engine,
            setBackgroundTracking: { [background] in background.record($0) },
            now: { [clock] in clock.now() },
            sleep: { [clock] in try await clock.sleep($0) }
        )
        let stream = manager.tripStates()
        Task { [states] in
            for await state in stream { await states.record(state) }
        }
    }

    func start() async {
        await manager.startTrip(route: route, destination: library)
    }

    /// Feeds one fix on the current trip's stream and waits until it is handled, then moves the clock on. A
    /// quarter-second offset keeps fix times apart from the clock times other state changes use.
    @discardableResult
    func fix(_ coordinate: GeoCoordinate, accuracy: Double = 5, then seconds: TimeInterval = 1) async -> TripState {
        let time = clock.now().addingTimeInterval(0.25)
        location.yield(LocationSample(coordinate: coordinate, horizontalAccuracy: accuracy, timestamp: time),
                       toStream: location.streamCount - 1)
        let state = await states.waitFor { $0.updatedAt == time || $0.phase == .arrived }
        clock.advance(by: seconds)
        return state
    }

    /// Lets a timer re-arm after `advance(by:)` woke it, so the next advance can't skip it.
    func waitForSleepers(_ count: Int) async {
        await waitUntil { clock.sleeperCount >= count }
    }

    func walk(from: Double, to: Double, lateral: Double = 0) async {
        for along in TripWalk.distances(from: from, to: to) {
            await fix(TripWalk.point(on: route, along: along, lateral: lateral))
        }
    }

    func point(_ along: Double, lateral: Double = 0) -> GeoCoordinate {
        TripWalk.point(on: route, along: along, lateral: lateral)
    }

    /// Releases a held reroute answer and waits until the manager has had it, two actor turns after it returned.
    func answerReroute() async {
        await router.respond()
        await waitUntil { await router.answered >= 1 }
        await manager.pauseTrip()
        await manager.pauseTrip()
    }

    /// 40 m to the left of `along`, then standing there; off route 10 s after passing 30 m, at the 32nd fix.
    func goOffRoute(at along: Double) async {
        for index in 1...32 {
            await fix(point(along, lateral: -min(1.4 * Double(index), 40)))
        }
    }
}

// MARK: Tests

// any hand-shake that never completes fails the test instead of hanging the run
@Suite(.timeLimit(.minutes(1)))
struct TripManagerTests {
    @Test
    func startPublishesTheFirstTurnAndAnnouncesTheTrip() async throws {
        let harness = try Harness()
        await harness.start()

        let state = await harness.states.waitFor { $0.phase == .active }
        #expect(state.destinationName == "Library")
        #expect(state.nextManeuver?.instruction == "Turn right onto Ferst Drive.")
        #expect(abs((state.distanceToNextManeuver ?? 0) - 100) < 0.01)
        #expect(abs((state.distanceRemaining ?? 0) - 160) < 0.01)
        #expect(harness.background.values == [true])

        // nothing is spoken until VoiceOver has moved focus
        #expect(await harness.engine.submitted.isEmpty)
        // the start delay and the watchdog
        await harness.waitForSleepers(2)
        harness.clock.advance(by: 0.75)
        let start = try #require(await harness.engine.waitForCount(1).first)
        #expect(start.text == "Starting directions to Library, about 160 metres. Walk north.")
        #expect(start.priority == .high)
        #expect(start.category == .maneuver)
        #expect(start.source == .navigation)
        #expect(start.expiresAt == start.createdAt.addingTimeInterval(15))
    }

    @Test
    func shortWalkSubmitsEachCueWithItsFields() async throws {
        let harness = try Harness()
        await harness.start()
        await harness.walk(from: 0, to: 160)

        let events = await harness.engine.waitForCount(5)
        #expect(events.map(\.text) == [
            "Starting directions to Library, about 160 metres. Walk north.",
            "In about 40 metres, turn right onto Ferst Drive.",
            "Turn right onto Ferst Drive.",
            "In about 40 metres, your destination is on the left.",
            "Arriving at Library. Your destination is on the left.",
        ])
        #expect(events.map(\.priority) == [.high, .normal, .high, .normal, .high])
        #expect(events.map(\.haptic) == [nil, nil, .turnRight, nil, .arrived])
        #expect(events.allSatisfy { $0.category == .maneuver && $0.source == .navigation })
        // the turn cue lasts long enough to walk the 7.6 m left at 1.3 m/s, plus 5 m
        let expiries = events.compactMap { event in event.expiresAt.map { $0.timeIntervalSince(event.createdAt) } }
        #expect(expiries.count == 5)
        #expect(Array(expiries.enumerated().filter { $0.offset != 2 }.map(\.element)) == [15, 8, 8, 15])
        #expect(abs(expiries[2] - (100 - 92.4 + 5) / 1.3) < 0.01)

        let startKey = try #require(events[0].dedupKey)
        let tripPrefix = String(startKey.dropLast("start".count))
        #expect(events.map { $0.dedupKey.map { String($0.dropFirst(tripPrefix.count)) } } == [
            "start", "step-1-prepare", "step-1-now", "step-2-prepare", "arrived",
        ])
        #expect(events.allSatisfy { $0.dedupKey?.hasPrefix(tripPrefix) == true })
    }

    @Test
    func pausedTripKeepsTrackingAndSpeaksTheMissedCueOnResume() async throws {
        let harness = try Harness()
        await harness.start()
        await harness.walk(from: 0, to: 50)
        await harness.manager.pauseTrip()
        #expect(await harness.states.waitFor { $0.phase == .paused }.phase == .paused)

        // the prepare at 60 m and the turn at 92 m fall due while paused
        await harness.walk(from: 51.8, to: 95.3)
        let paused = try #require(await harness.states.current)
        #expect(paused.phase == .paused)
        #expect(abs((paused.distanceRemaining ?? 0) - (160 - 95.2)) < 0.01)
        #expect(await harness.engine.texts == [
            "Starting directions to Library, about 160 metres. Walk north.", "Trip paused.",
        ])

        await harness.manager.resumeTrip()
        await harness.fix(harness.point(96.6))
        await harness.fix(harness.point(98.0))
        let texts = await harness.engine.texts
        // 4.8 m from the turn on resume says nothing of it; the next fix gives the turn, once
        #expect(Array(texts.dropFirst(2)) == ["Trip resumed.", "Turn right onto Ferst Drive."])
        let confirmations = await harness.engine.submitted.filter { $0.text.hasPrefix("Trip ") }
        #expect(confirmations.allSatisfy { $0.dedupKey == nil && $0.priority == .high && $0.expiresAt == nil })
    }

    @Test
    func arrivalWhilePausedIsAnnouncedOnResume() async throws {
        let harness = try Harness()
        await harness.start()
        await harness.walk(from: 0, to: 140)
        await harness.manager.pauseTrip()
        // arrives at 151.2 m, within 10 m of the end
        for along in TripWalk.distances(from: 141.4, to: 151.3) {
            await harness.fix(harness.point(along))
        }
        let arrived = try #require(await harness.states.current)
        #expect(arrived.phase == .paused)
        await harness.location.waitForTermination(ofStream: 0)
        await waitUntil { harness.background.values == [true, false] }

        await harness.manager.resumeTrip()
        #expect(await harness.states.waitFor { $0.phase == .arrived }.phase == .arrived)
        let texts = await harness.engine.waitForCount(7)
        #expect(Array(texts.map(\.text).suffix(2)) == [
            "Trip resumed.", "Arriving at Library. Your destination is on the left.",
        ])
    }

    @Test
    func endingDuringASubmitDropsTheRestOfThatFix() async throws {
        let harness = try Harness()
        await harness.start()
        await harness.fix(harness.point(0), then: 0)
        // no fix for 20 s: the watchdog warns, and the speed cap allows the jump to 60 m. That fix brings the signal
        // back and a prepare together.
        for _ in 0..<4 {
            await harness.waitForSleepers(1)
            harness.clock.advance(by: 5)
        }
        await harness.engine.waitForCount(2)
        await harness.engine.hold(text: "GPS signal is back.")
        let first = Task { await harness.fix(harness.point(60.2)) }
        await harness.engine.waitUntilHeld()

        await harness.manager.endTrip()
        // a new trip is active when the held submission returns, so only the generation check stops the prepare
        await harness.start()
        await harness.engine.release()
        _ = await first.value
        await harness.location.waitForTermination(ofStream: 0)
        await harness.walk(from: 0, to: 30)

        let texts = await harness.engine.texts
        #expect(!texts.contains("In about 40 metres, turn right onto Ferst Drive."))
        let ended = try #require(texts.firstIndex(of: "Trip ended."))
        #expect(texts[..<ended].last == "GPS signal is back.")
    }

    @Test
    func secondStartReplacesTheFirstTrip() async throws {
        let harness = try Harness()
        await harness.start()
        await harness.walk(from: 0, to: 20)
        await harness.start()
        await harness.location.waitForTermination(ofStream: 0)
        await harness.states.waitFor { abs(($0.distanceRemaining ?? 0) - 160) < 0.01 }
        // the second trip's start delay and watchdog; the first trip's were cancelled
        await harness.waitForSleepers(2)

        // a late fix on the first trip's stream goes nowhere
        harness.location.yield(LocationSample(coordinate: harness.point(80), horizontalAccuracy: 5,
                                              timestamp: harness.clock.now()), toStream: 0)
        await harness.fix(harness.point(1.4))
        let state = try #require(await harness.states.current)
        #expect(abs((state.distanceRemaining ?? 0) - (160 - 1.4)) < 0.01)

        let starts = await harness.engine.waitForCount(2).filter { $0.text.hasPrefix("Starting directions") }
        #expect(starts.count == 2)
        #expect(starts[0].dedupKey != starts[1].dedupKey)
    }

    @Test
    func offRouteReroutesOnceAndFollowsTheNewRoute() async throws {
        // where the user stands off route: 49 m along, 40 m to the left
        let origin = TripWalk.point(on: try cornerRoute(), along: 49, lateral: -40)
        let harness = try Harness(reroutes: [.success(try eastRoute(from: origin))])
        await harness.start()
        await harness.walk(from: 0, to: 50)
        let along = TripWalk.distances(from: 0, to: 50).last ?? 0
        // 40 m to the left, then standing there; off route 10 s after passing 30 m
        for index in 1...40 {
            await harness.fix(harness.point(along, lateral: -min(1.4 * Double(index), 40)))
        }
        await harness.router.waitForRequests(1)
        #expect(await harness.engine.texts.contains("You're off the route. Finding a new route."))
        let offRoute = try #require(await harness.states.current)
        #expect(offRoute.nextManeuver?.instruction == "Off route. Finding a new route.")
        #expect(offRoute.distanceToNextManeuver == nil)

        await harness.router.respond()
        let rerouted = await harness.states.waitFor { $0.nextManeuver?.instruction == "Arrive" }
        #expect(abs((rerouted.distanceRemaining ?? 0) - 80) < 0.5)
        await harness.engine.waitForCount(3)
        #expect(await harness.engine.texts.last == "New route. Head east.")

        // the new route is followed, with no second request
        for along in TripWalk.distances(from: 0, to: 10) {
            await harness.fix(TripWalk.destination(from: origin, bearing: 90, distance: along))
        }
        #expect(await harness.router.requests.count == 1)
        let following = try #require(await harness.states.current)
        #expect(abs((following.distanceRemaining ?? 0) - (80 - 9.8)) < 0.5)
    }

    @Test
    func reroutesWaitThirtySecondsAndStopAfterFive() async throws {
        let harness = try Harness(reroutes: Array(repeating: .failure(.serverUnavailable), count: 6))
        await harness.start()
        await harness.walk(from: 0, to: 50)
        let along = TripWalk.distances(from: 0, to: 50).last ?? 0
        for index in 1...40 {
            await harness.fix(harness.point(along, lateral: -min(1.4 * Double(index), 40)))
        }
        await harness.router.waitForRequests(1)
        let away = harness.point(along, lateral: -40)

        // fixes a second apart don't ask again before 30 s
        for _ in 0..<5 { await harness.fix(away) }
        #expect(await harness.router.requests.count == 1)
        for attempt in 2...5 {
            await harness.fix(away, then: 30)
            await harness.fix(away)
            await harness.router.waitForRequests(attempt)
        }
        await waitUntil {
            let texts = await harness.engine.texts
            return texts.filter { $0 == "Couldn't get a new route. Walk back the way you came." }.count == 4
                && texts.contains("Off route. End the trip and choose your destination again.")
        }
        for _ in 0..<3 { await harness.fix(away, then: 30) }
        await harness.fix(away)
        #expect(await harness.router.requests.count == 5)
        let texts = await harness.engine.texts
        #expect(texts.filter { $0 == "Off route. End the trip and choose your destination again." }.count == 1)
        #expect(await harness.states.current?.nextManeuver?.instruction == "Off route. Head back toward the path.")
    }

    @Test
    func watchdogWarnsOfWeakSignalAndItsReturn() async throws {
        let harness = try Harness()
        await harness.start()
        await harness.fix(harness.point(0), then: 0)
        // the watchdog checks every 5 s; 10 s without a good fix is weak
        harness.clock.advance(by: 5)
        await harness.waitForSleepers(1)
        await harness.fix(harness.point(1.4), accuracy: 40, then: 5)
        // the last good fix was a quarter second into the trip, so the check at 15 s is the first past 10 s
        await harness.waitForSleepers(1)
        harness.clock.advance(by: 5)
        let warned = await harness.engine.waitForCount(2)
        let weak = try #require(warned.last)
        #expect(weak.text == "GPS signal is weak. Directions may be delayed.")
        #expect(weak.category == .system)

        await harness.fix(harness.point(2.8))
        let back = try #require(await harness.engine.waitForCount(3).last)
        #expect(back.text == "GPS signal is back.")
        #expect(back.category == .system)
    }

    @Test
    func undeliveredTurnCueIsResubmittedOnce() async throws {
        let harness = try Harness()
        await harness.engine.setAutoDelivers(false)
        await harness.start()
        await harness.walk(from: 0, to: 93)
        // standing short of the turn until the cue's 9.7 s run out and it is sent again, then well beyond
        var turns: [AnnouncementEvent] = []
        while turns.count < 2 {
            await harness.fix(harness.point(92.4))
            turns = await harness.engine.submitted.filter { $0.text == "Turn right onto Ferst Drive." }
        }
        #expect(turns.last?.dedupKey?.hasSuffix("-step-1-now-r1") == true)
        for _ in 0..<20 { await harness.fix(harness.point(92.4)) }
        #expect(await harness.engine.submitted.filter { $0.text == "Turn right onto Ferst Drive." }.count == 2)
    }

    @Test
    func deliveredTurnCueIsNotResubmitted() async throws {
        let harness = try Harness()
        await harness.start()
        await harness.walk(from: 0, to: 93)
        // until the delivery check for the cue's 9.7 s has woken, and two fixes more for it to finish
        while !harness.clock.hasWoken(after: (100 - 92.4 + 5) / 1.3) {
            await harness.fix(harness.point(92.4))
        }
        for _ in 0..<2 { await harness.fix(harness.point(92.4)) }

        let turns = await harness.engine.submitted.filter { $0.text == "Turn right onto Ferst Drive." }
        #expect(turns.count == 1)
    }

    @Test
    func backgroundTrackingRunsOnlyDuringATrip() async throws {
        let harness = try Harness()
        await harness.start()
        #expect(harness.background.values == [true])
        await harness.manager.endTrip()
        #expect(harness.background.values == [true, false])
        #expect(await harness.states.waitFor { $0.phase == .planning }.phase == .planning)
        #expect(await harness.engine.texts.last == "Trip ended.")

        await harness.start()
        await harness.walk(from: 0, to: 160)
        #expect(await harness.states.current?.phase == .arrived)
        await waitUntil { harness.background.values.count == 4 }
        #expect(harness.background.values == [true, false, true, false])
    }

    @Test
    func rejoiningOnTheFixThatWouldRerouteAsksForNothing() async throws {
        let harness = try Harness(reroutes: [.success(try eastRoute(from: harness0Origin))])
        await harness.start()
        await harness.walk(from: 0, to: 50)
        await harness.goOffRoute(at: 49)
        #expect(await harness.states.current?.nextManeuver?.instruction == "Off route. Finding a new route.")
        // two rough fixes back on the route start the rejoin; the precise third confirms it
        await harness.fix(harness.point(49, lateral: -5), accuracy: 22)
        await harness.fix(harness.point(49, lateral: -5), accuracy: 22)
        await harness.fix(harness.point(49, lateral: -5))
        await harness.fix(harness.point(50.4))
        #expect(await harness.states.current?.nextManeuver?.instruction == "Turn right onto Ferst Drive.")
        #expect(await harness.router.requests.isEmpty)
    }

    @Test
    func rerouteAnswerAfterARejoinIsDropped() async throws {
        let harness = try Harness(reroutes: [.success(try eastRoute(from: harness0Origin))])
        await harness.start()
        await harness.walk(from: 0, to: 50)
        await harness.goOffRoute(at: 49)
        await harness.fix(harness.point(49, lateral: -40))
        await harness.router.waitForRequests(1)
        for _ in 0..<3 { await harness.fix(harness.point(49)) }
        #expect(await harness.engine.texts.contains("Back on the route."))

        await harness.answerReroute()
        // the pause above is the only state change
        #expect(await harness.states.current?.nextManeuver?.instruction == "Turn right onto Ferst Drive.")
        #expect(await !harness.engine.texts.contains("New route. Head east."))
    }

    @Test
    func rerouteAnswerAfterArrivalIsDropped() async throws {
        let harness = try Harness(reroutes: [.success(try eastRoute(from: harness0Origin))])
        await harness.start()
        await harness.walk(from: 0, to: 140)
        await harness.goOffRoute(at: 138.6)
        await harness.fix(harness.point(138.6, lateral: -40))
        await harness.router.waitForRequests(1)
        // a precise fix at the destination arrives while still off route
        let arrived = await harness.fix(harness.point(160))
        #expect(arrived.phase == .arrived)

        await waitUntil { await harness.engine.texts.contains("Arriving at Library. Your destination is on the left.") }
        await harness.answerReroute()
        #expect(await harness.states.current == arrived)
        #expect(await !harness.engine.texts.contains("New route. Head east."))
    }

    @Test(arguments: [false, true])
    func rerouteInFlightWhenTheTripEndsOrRestartsIsDropped(_ restarts: Bool) async throws {
        let harness = try Harness(reroutes: [.success(try eastRoute(from: harness0Origin))])
        await harness.start()
        await harness.walk(from: 0, to: 50)
        await harness.goOffRoute(at: 49)
        await harness.fix(harness.point(49, lateral: -40))
        await harness.router.waitForRequests(1)

        if restarts {
            await harness.start()
        } else {
            await harness.manager.endTrip()
        }
        await harness.answerReroute()
        if restarts {
            await harness.manager.resumeTrip()
            await harness.fix(harness.point(0))
            #expect(await harness.states.current?.nextManeuver?.instruction == "Turn right onto Ferst Drive.")
            #expect(abs((await harness.states.current?.distanceRemaining ?? 0) - 160) < 0.01)
        } else {
            #expect(await harness.states.current?.phase == .planning)
        }
        #expect(await !harness.engine.texts.contains("New route. Head east."))
    }

    @Test
    func turnCueHeldBackByAPauseIsNeverResent() async throws {
        let harness = try Harness()
        await harness.start()
        await harness.fix(harness.point(0), then: 0)
        // 30 s without a fix: the watchdog warns, and the speed cap allows the jump to 92.4 m. That fix brings the
        // signal back and the turn cue together.
        for _ in 0..<6 {
            await harness.waitForSleepers(1)
            harness.clock.advance(by: 5)
        }
        await harness.engine.waitForCount(2)
        await harness.engine.hold(text: "GPS signal is back.")
        let turnFix = Task { await harness.fix(harness.point(92.4)) }
        await harness.engine.waitUntilHeld()
        await harness.manager.pauseTrip()
        await harness.engine.release()
        _ = await turnFix.value
        // a fix while still paused is handled only after that fix's loop has finished
        await harness.fix(harness.point(92.4))

        await harness.manager.resumeTrip()
        for _ in 0..<20 { await harness.fix(harness.point(92.4)) }
        let texts = await harness.engine.texts
        // the held-back cue is never resent; the tracker gives the turn afresh on the first fix after resuming
        let turns = await harness.engine.submitted.filter { $0.text == "Turn right onto Ferst Drive." }
        #expect(turns.count == 1)
        #expect(turns.allSatisfy { $0.dedupKey?.hasSuffix("-step-1-now") == true })
        let resumed = try #require(texts.firstIndex(of: "Trip resumed."))
        #expect(texts.firstIndex(of: "Turn right onto Ferst Drive.") == resumed + 1)
    }

    @Test
    func resumeSpeaksTheDueCueOnceAndTheNextFixDoesntRepeatIt() async throws {
        let harness = try Harness()
        await harness.start()
        await harness.walk(from: 0, to: 50)
        await harness.manager.pauseTrip()
        // the prepare at 60 m falls due while paused; resume at 70 m says it
        await harness.walk(from: 50.4, to: 70.1)
        await harness.manager.resumeTrip()
        await harness.walk(from: 71.4, to: 93)

        let texts = await harness.engine.texts
        #expect(texts.filter { $0.hasSuffix("turn right onto Ferst Drive.") } == [
            "In about 30 metres, turn right onto Ferst Drive.",
        ])
        #expect(texts.filter { $0 == "Turn right onto Ferst Drive." }.count == 1)
    }

    @Test
    func resumePastATurnDoesntSayTheTurn() async throws {
        let harness = try Harness()
        await harness.start()
        await harness.walk(from: 0, to: 100)
        await harness.manager.pauseTrip()
        // straight on past the right turn at 100 m; progress stays at the turn
        let corner = harness.route.coordinates[1]
        for metres in TripWalk.distances(from: 1.4, to: 20) {
            await harness.fix(TripWalk.destination(from: corner, bearing: 0, distance: metres))
        }
        await harness.manager.resumeTrip()
        await harness.fix(TripWalk.destination(from: corner, bearing: 0, distance: 21))

        let texts = await harness.engine.texts
        let resumed = try #require(texts.firstIndex(of: "Trip resumed."))
        #expect(!texts[resumed...].contains { $0.hasPrefix("Turn ") || $0.contains("turn right onto") })
        #expect(texts.filter { $0 == "Turn right onto Ferst Drive." }.count == 1)
    }

    @Test
    func resumeSpeechForARouteReplacedMeanwhileIsDropped() async throws {
        let harness = try Harness(reroutes: [.success(try eastRoute(from: harness0Origin))])
        await harness.start()
        await harness.walk(from: 0, to: 50)
        await harness.goOffRoute(at: 49)
        await harness.fix(harness.point(49, lateral: -40))
        await harness.router.waitForRequests(1)
        await harness.manager.pauseTrip()

        // the new route lands while "Trip resumed." is being said
        await harness.engine.hold(text: "Trip resumed.")
        let resuming = Task { await harness.manager.resumeTrip() }
        await harness.engine.waitUntilHeld()
        await harness.router.respond()
        await waitUntil { await harness.engine.texts.contains("New route. Head east.") }
        await harness.engine.release()
        await resuming.value

        let texts = await harness.engine.texts
        let resumed = try #require(texts.firstIndex(of: "Trip resumed."))
        #expect(!texts[resumed...].contains("You're off the route. Finding a new route."))
    }
}
