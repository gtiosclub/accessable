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

    let headings = ManualFeed<HeadingSample>()

    func headingSamples() -> AsyncStream<HeadingSample> {
        headings.stream()
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

/// Values the test sends, in order, on the latest subscriber's stream. Counts how often the subscriber asks for
/// the next one: it asks only once it has handled the last, so the count tells the test when handling is done.
private final class ManualFeed<Element: Sendable>: Sendable {
    private struct Feed {
        var buffer: [Element] = []
        var waiter: CheckedContinuation<Element?, Never>?
        var requests = 0
        var sent = 0
    }

    private enum Next { case value(Element), end, wait }

    private let feeds = Mutex<[Feed]>([])

    func stream() -> AsyncStream<Element> {
        let index = feeds.withLock { feeds in
            feeds.append(Feed())
            return feeds.count - 1
        }
        return AsyncStream(unfolding: { [self] in await next(on: index) })
    }

    func yield(_ element: Element) {
        let waiter = feeds.withLock { feeds -> CheckedContinuation<Element?, Never>? in
            guard let last = feeds.indices.last else { return nil }
            feeds[last].sent += 1
            guard let waiter = feeds[last].waiter else {
                feeds[last].buffer.append(element)
                return nil
            }
            feeds[last].waiter = nil
            return waiter
        }
        waiter?.resume(returning: element)
    }

    /// Waits until the latest subscriber has handled everything sent to it.
    func waitUntilHandled() async {
        await waitUntil {
            feeds.withLock { feeds in feeds.last.map { $0.waiter != nil && $0.requests > $0.sent } ?? false }
        }
    }

    private func next(on index: Int) async -> Element? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Element?, Never>) in
                let next = feeds.withLock { feeds -> Next in
                    feeds[index].requests += 1
                    if Task.isCancelled { return .end }
                    if !feeds[index].buffer.isEmpty { return .value(feeds[index].buffer.removeFirst()) }
                    feeds[index].waiter = continuation
                    return .wait
                }
                switch next {
                case .value(let element): continuation.resume(returning: element)
                case .end: continuation.resume(returning: nil)
                case .wait: break
                }
            }
        } onCancel: {
            let waiter = feeds.withLock { feeds in
                defer { feeds[index].waiter = nil }
                return feeds[index].waiter
            }
            waiter?.resume(returning: nil)
        }
    }
}

extension ManualFeed: LandmarkObserving where Element == LandmarkObservation {
    func landmarkObservations() -> AsyncStream<LandmarkObservation> {
        stream()
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

/// How a route with an unknown heading is set off on, from its "Walk north." or "Head east.".
private let setOff = "Follow the path. You'll be warned if it's the wrong way."
private let newRouteSpeech = "New route. \(setOff)"

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
    let landmarks = ManualFeed<LandmarkObservation>()
    let states = StateRecorder()
    let manager: TripManager
    let route: NavigationRoute

    /// No campus buildings or crossings by default, so only the landmark and crossing tests have any.
    init(
        route: NavigationRoute? = nil,
        reroutes: [Result<NavigationRoute, RoutingError>] = [],
        buildings: [CampusBuilding] = [],
        crossings: [CampusCrossing] = [],
        distances: DistanceSettings = DistanceSettings(units: .metres),
        recorder: TripRecorder? = nil,
        savedTrips: SavedTripStore? = nil
    ) throws {
        let route = try route ?? cornerRoute()
        self.route = route
        router = ScriptedRouter(reroutes)
        manager = TripManager(
            location: location, routing: router, announcements: engine,
            landmarks: landmarks, campusBuildings: { buildings }, campusCrossings: { crossings },
            setTripTracking: { [background] in background.record($0) },
            distances: distances,
            recorder: recorder,
            savedTrips: savedTrips,
            now: { [clock] in clock.now() },
            sleep: { [clock] in try await clock.sleep($0) }
        )
        let stream = manager.tripStates()
        Task { [states] in
            for await state in stream { await states.record(state) }
        }
    }

    func start(to destination: Destination = library) async {
        await manager.startTrip(route: route, destination: destination)
    }

    /// Feeds one fix on the current trip's stream and waits until it is handled, then moves the clock on. A
    /// quarter-second offset keeps fix times apart from the clock times other state changes use. A `course` comes
    /// with a walking speed, so the fix gives the heading. A `timestamp` stands for a fix that arrives late.
    @discardableResult
    func fix(_ coordinate: GeoCoordinate, accuracy: Double = 5, course: Double? = nil, timestamp: Date? = nil,
             then seconds: TimeInterval = 1) async -> TripState {
        let time = timestamp ?? clock.now().addingTimeInterval(0.25)
        location.yield(LocationSample(coordinate: coordinate, horizontalAccuracy: accuracy, timestamp: time,
                                      speed: course.map { _ in 1.4 }, course: course),
                       toStream: location.streamCount - 1)
        let state = await states.waitFor { $0.updatedAt == time || $0.phase == .arrived }
        clock.advance(by: seconds)
        return state
    }

    /// Lets a timer re-arm after `advance(by:)` woke it, so the next advance can't skip it.
    func waitForSleepers(_ count: Int) async {
        await waitUntil { clock.sleeperCount >= count }
    }

    /// - Parameter course: The heading at each distance along, or none for fixes without one.
    func walk(from: Double, to: Double, lateral: Double = 0, course: ((Double) -> Double)? = nil) async {
        for along in TripWalk.distances(from: from, to: to) {
            await fix(TripWalk.point(on: route, along: along, lateral: lateral), course: course?(along))
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
        #expect(start.text == "Starting directions to Library, about 160 metres. \(setOff)")
        #expect(start.priority == .high)
        #expect(start.category == .maneuver)
        #expect(start.source == .navigation)
        #expect(start.expiresAt == start.createdAt.addingTimeInterval(15))
    }

    @Test
    func switchingToFeetChangesTheNextCue() async throws {
        let distances = DistanceSettings(units: .metres)
        let harness = try Harness(distances: distances)
        await harness.start()
        await harness.waitForSleepers(2)
        harness.clock.advance(by: 0.75)
        let start = try #require(await harness.engine.waitForCount(1).first)
        #expect(start.text == "Starting directions to Library, about 160 metres. \(setOff)")

        // changed in Settings mid-trip: the next cue is in feet, 40 m rounded to 25 ft steps
        distances.units = .feet
        await harness.walk(from: 0, to: 160)
        let texts = await harness.engine.waitForCount(5).map(\.text)
        #expect(texts[1] == "In about 125 feet, turn right onto Ferst Drive.")
        #expect(texts[3] == "In about 125 feet, your destination is on the left.")
    }

    @Test
    func shortWalkSubmitsEachCueWithItsFields() async throws {
        let harness = try Harness()
        await harness.start()
        await harness.walk(from: 0, to: 160)

        let events = await harness.engine.waitForCount(5)
        #expect(events.map(\.text) == [
            "Starting directions to Library, about 160 metres. \(setOff)",
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

    @Test(arguments: [("Take the stairs up.", "stairs going up"), ("Take the stairs.", "stairs")])
    func stairsWarningSaysWhichWayAndTheCueKeepsValhallasWords(_ instruction: String, _ phrase: String)
        async throws {
        let corner = try cornerRoute()
        var steps = corner.steps
        steps[1] = RouteStep(kind: .stairs, coordinateIndex: 1, instruction: instruction,
                             spokenInstruction: instruction)
        let harness = try Harness(route: try NavigationRoute(coordinates: corner.coordinates, steps: steps,
                                                             estimatedDuration: corner.estimatedDuration))
        await harness.start()
        await harness.walk(from: 0, to: 160)

        let events = await harness.engine.waitForCount(5)
        #expect(events[1].text == "In about 40 metres, \(phrase).")
        // said even with Important only, and still in time behind a long start sentence
        #expect(events[1].priority == .high)
        #expect(events[1].expiresAt == events[1].createdAt.addingTimeInterval(15))
        #expect(events[2].text == instruction)
        #expect(events[2].haptic == .attention)
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
            "Starting directions to Library, about 160 metres. \(setOff)", "Trip paused.",
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
        #expect(arrived.hasArrived)
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
        #expect(offRoute.isOffRoute)

        await harness.router.respond()
        let rerouted = await harness.states.waitFor { $0.nextManeuver?.instruction == "Arrive" }
        #expect(abs((rerouted.distanceRemaining ?? 0) - 80) < 0.5)
        #expect(!rerouted.isOffRoute)
        // the map redraws from this stream
        var routes = harness.manager.tripRoutes().makeAsyncIterator()
        let latest = try #require(await routes.next())
        #expect(latest == (try eastRoute(from: origin)))
        await harness.engine.waitForCount(3)
        #expect(await harness.engine.texts.last == newRouteSpeech)

        // the new route is followed, with no second request
        for along in TripWalk.distances(from: 0, to: 10) {
            await harness.fix(TripWalk.destination(from: origin, bearing: 90, distance: along))
        }
        #expect(await harness.router.requests.count == 1)
        let following = try #require(await harness.states.current)
        #expect(abs((following.distanceRemaining ?? 0) - (80 - 9.8)) < 0.5)
    }

    @Test
    func rerouteStartsFromTheFixThatFindsTheUserOffRoute() async throws {
        let harness = try Harness(reroutes: [.success(try eastRoute(from: harness0Origin))])
        await harness.start()
        await harness.walk(from: 0, to: 50)
        // off route on the 32nd fix, with no fix after it
        await harness.goOffRoute(at: 49)
        await harness.router.waitForRequests(1)
        #expect(await harness.router.requests == [harness0Origin])
        #expect(await harness.engine.texts.last == "You're off the route. Finding a new route.")
    }

    @Test
    func askedForRerouteWhileOnTheRouteFollowsTheNewRoute() async throws {
        // Route Blocked Ahead's "find another way": still on the route, so no off-route reroute would come
        let walked = TripWalk.distances(from: 0, to: 20).last ?? 0
        let origin = TripWalk.point(on: try cornerRoute(), along: walked)
        let harness = try Harness(reroutes: [.success(try eastRoute(from: origin))])
        await harness.start()
        await harness.walk(from: 0, to: 20)

        await harness.manager.reroute()
        await harness.router.waitForRequests(1)
        #expect(await harness.router.requests == [origin])

        await harness.router.respond()
        let rerouted = await harness.states.waitFor { $0.nextManeuver?.instruction == "Arrive" }
        #expect(abs((rerouted.distanceRemaining ?? 0) - 80) < 0.5)
        await waitUntil { await harness.engine.texts.contains(newRouteSpeech) }
        let texts = await harness.engine.texts
        #expect(texts.contains("Finding a new route from here."))
        #expect(!texts.contains("Trip ended."))
    }

    @Test
    func askedForRerouteWithoutAPreciseFixSaysSoAndAsksNothing() async throws {
        let harness = try Harness()
        await harness.start()
        await harness.fix(harness.point(5), accuracy: 50)

        await harness.manager.reroute()
        #expect(await harness.router.requests.isEmpty)
        #expect(await harness.engine.texts.contains(
            "Couldn't find where you are precisely enough for a new route. Try again in a moment."
        ))
    }

    @Test
    func askedForRerouteWithAWeakSignalDoesntStartFromAnOldFix() async throws {
        let harness = try Harness()
        await harness.start()
        await harness.fix(harness.point(0), then: 0)
        // as in watchdogWarnsOfWeakSignalAndItsReturn: 10 s without a good fix is weak
        harness.clock.advance(by: 5)
        await harness.waitForSleepers(1)
        await harness.fix(harness.point(1.4), accuracy: 40, then: 5)
        await harness.waitForSleepers(1)
        harness.clock.advance(by: 5)
        await waitUntil { await harness.engine.texts.contains("GPS signal is weak. Directions may be delayed.") }

        await harness.manager.reroute()
        #expect(await harness.router.requests.isEmpty)
        #expect(await harness.engine.texts.contains(
            "Couldn't find where you are precisely enough for a new route. Try again in a moment."
        ))
    }

    @Test
    func askedForRerouteThatFailsKeepsTheCurrentRoute() async throws {
        let harness = try Harness(reroutes: [.failure(.serverUnavailable)])
        await harness.start()
        await harness.walk(from: 0, to: 20)

        await harness.manager.reroute()
        await harness.router.waitForRequests(1)
        await harness.router.respond()
        await waitUntil {
            await harness.engine.texts.contains("Couldn't get a new route. Keep following the current one.")
        }
        // still on the route, so nothing sends the user back
        #expect(!(await harness.engine.texts.contains("Couldn't get a new route. Walk back the way you came.")))
    }

    @Test
    func askedForRerouteWithNoTripDoesNothing() async throws {
        let harness = try Harness()
        await harness.manager.reroute()
        #expect(await harness.router.requests.isEmpty)
        #expect(await harness.engine.texts.isEmpty)
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
    func afterASuccessfulRerouteTheNextWaitsFifteenSeconds() async throws {
        let harness = try Harness(reroutes: [.success(try eastRoute(from: harness0Origin))])
        await harness.start()
        await harness.walk(from: 0, to: 50)
        // the first request goes out on the fix that finds the user off route, at the clock time 15 s before the
        // second may
        await harness.goOffRoute(at: 49)
        await harness.router.waitForRequests(1)
        await harness.router.respond()
        await harness.states.waitFor { $0.nextManeuver?.instruction == "Arrive" }

        // walking north away from the new route, already 25 m off it: off route on the sixth fix, 6 s after the
        // first request
        for index in 1...6 {
            let north = TripWalk.destination(from: harness0Origin, bearing: 0, distance: 25 + 1.4 * Double(index))
            await harness.fix(north, course: 0)
        }
        let away = TripWalk.destination(from: harness0Origin, bearing: 0, distance: 40)
        await harness.fix(away, then: 7)
        // 14 s after the first request
        await harness.fix(away)
        #expect(await harness.router.requests.count == 1)
        await harness.fix(away)
        await harness.router.waitForRequests(2)
    }

    @Test
    func afterAFailedRerouteTheNextStillWaitsThirtySeconds() async throws {
        let harness = try Harness(reroutes: [.failure(.serverUnavailable), .failure(.serverUnavailable)])
        await harness.start()
        await harness.walk(from: 0, to: 50)
        // the first request goes out on the fix that finds the user off route
        await harness.goOffRoute(at: 49)
        let away = harness.point(49, lateral: -40)
        await harness.router.waitForRequests(1)
        await waitUntil {
            await harness.engine.texts.contains("Couldn't get a new route. Walk back the way you came.")
        }

        // 1 s, 15 s and 29 s after the first request
        await harness.fix(away, then: 14)
        await harness.fix(away, then: 14)
        await harness.fix(away)
        #expect(await harness.router.requests.count == 1)
        await harness.fix(away)
        await harness.router.waitForRequests(2)
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
        // found off route by a fix too rough to start a route from, so the reroute waits for a precise one
        for index in 1...32 {
            await harness.fix(harness.point(49, lateral: -min(1.4 * Double(index), 40)), accuracy: index == 32 ? 22 : 5)
        }
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
        // a fix's state is published before its cue is submitted, so wait for the cue
        await waitUntil { await harness.engine.texts.contains("Back on the route.") }

        await harness.answerReroute()
        // the pause above is the only state change
        #expect(await harness.states.current?.nextManeuver?.instruction == "Turn right onto Ferst Drive.")
        #expect(await !harness.engine.texts.contains(newRouteSpeech))
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
        #expect(await !harness.engine.texts.contains(newRouteSpeech))
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
        #expect(await !harness.engine.texts.contains(newRouteSpeech))
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
        // a fix's state is published before its cue is submitted, so wait for the last cue
        await waitUntil { await harness.engine.texts.contains("Turn right onto Ferst Drive.") }

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
        await waitUntil { await harness.engine.texts.contains(newRouteSpeech) }
        await harness.engine.release()
        await resuming.value

        let texts = await harness.engine.texts
        let resumed = try #require(texts.firstIndex(of: "Trip resumed."))
        #expect(!texts[resumed...].contains("You're off the route. Finding a new route."))
    }
}

// MARK: Crossings

private func isCrossingCue(_ event: AnnouncementEvent) -> Bool {
    event.dedupKey?.contains("-crossing-") == true
}

@Suite(.timeLimit(.minutes(1)))
struct TripManagerCrossingTests {
    @Test(arguments: [
        (CampusCrossing.Control.signals, true, "Crosswalk ahead, with audible signal."),
        (.signals, false, "Crosswalk ahead, with a traffic signal."),
        (.marked, false, "Crosswalk ahead."),
        (.unknown, false, "Road crossing ahead."),
        (.unmarked, false, "Road crossing ahead, unmarked."),
    ])
    func crossingAheadIsSpokenForItsControl(_ control: CampusCrossing.Control, _ audibleSignal: Bool,
                                            _ expected: String) async throws {
        let crosswalk = CampusCrossing(coordinate: TripWalk.point(on: try cornerRoute(), along: 50), control: control,
                                       audibleSignal: audibleSignal)
        let harness = try Harness(crossings: [crosswalk])
        await harness.start()
        // the crossing falls due at 30 m, before the turn's prepare at 60 m
        await harness.walk(from: 0, to: 45)

        let events = await harness.engine.waitForCount(2)
        let event = try #require(events.first(where: isCrossingCue))
        #expect(events.filter(isCrossingCue).count == 1)
        #expect(event.text == expected)
        #expect(event.priority == .high)
        #expect(event.haptic == .attention)
        #expect(event.category == .maneuver)
        #expect(event.expiresAt == event.createdAt.addingTimeInterval(8))
        #expect(event.dedupKey?.hasSuffix("-v0-crossing-0") == true)
    }

    @Test
    func rerouteUsesTheNewRoutesCrossings() async throws {
        let newRoute = try eastRoute(from: harness0Origin)
        // one ahead on the old route that the walk never reaches, and one 50 m along the new route
        let oldRouteCrossing = CampusCrossing(coordinate: TripWalk.point(on: try cornerRoute(), along: 80),
                                              control: .marked, audibleSignal: false)
        let newRouteCrossing = CampusCrossing(coordinate: TripWalk.point(on: newRoute, along: 50), control: .signals,
                                              audibleSignal: false)
        let harness = try Harness(reroutes: [.success(newRoute)], crossings: [oldRouteCrossing, newRouteCrossing])
        await harness.start()
        await harness.walk(from: 0, to: 50)
        await harness.goOffRoute(at: 49)
        // the request goes out on the fix after the off-route cue
        await harness.fix(harness0Origin)
        await harness.router.waitForRequests(1)
        await harness.router.respond()
        _ = await harness.states.waitFor { $0.nextManeuver?.instruction == "Arrive" }
        await harness.engine.waitForCount(3)
        #expect(!(await harness.engine.submitted.contains(where: isCrossingCue)))

        // due at 30 m along the new route, before the arrival's prepare at 40 m
        for along in TripWalk.distances(from: 0, to: 35) {
            await harness.fix(TripWalk.destination(from: harness0Origin, bearing: 90, distance: along))
        }
        let events = await harness.engine.waitForCount(4)
        let crossings = events.filter(isCrossingCue)
        #expect(crossings.map(\.text) == ["Crosswalk ahead, with a traffic signal."])
        #expect(crossings.first?.dedupKey?.hasSuffix("-v1-crossing-0") == true)
    }
}

// MARK: Landmarks

/// A square building `size` metres across, centred `lateral` metres right of the corner route at `along`.
private func building(_ name: String, aliases: [String] = [], along: Double, lateral: Double, size: Double = 6,
                      entrances: [CampusEntrance] = []) throws -> CampusBuilding {
    let route = try cornerRoute()
    let half = size / 2
    let corners = [(-half, -half), (-half, half), (half, half), (half, -half)].map { along_, lateral_ in
        TripWalk.point(on: route, along: along + along_, lateral: lateral + lateral_)
    }
    return CampusBuilding(name: name, aliases: aliases, outlines: [corners], entrances: entrances)
}

private func sign(_ text: String, announced: Bool = false) -> LandmarkObservation {
    LandmarkObservation(kind: .signText, text: text, key: text.lowercased(), confidence: 0.9, wasAnnounced: announced)
}

@Suite(.timeLimit(.minutes(1)))
struct TripManagerLandmarkTests {
    @Test
    func signBesideTheRouteIsSpokenWithItsSide() async throws {
        let skiles = try building("William Vernon Skiles Building", aliases: ["Skiles"], along: 50, lateral: 15)
        let harness = try Harness(buildings: [skiles])
        await harness.start()
        await harness.walk(from: 0, to: 30)
        let before = await harness.engine.submitted.count

        harness.landmarks.yield(sign("SKILES"))
        let event = try #require(await harness.engine.waitForCount(before + 1).last)

        #expect(event.text == "Passing Skiles on your right.")
        #expect(event.category == .landmark)
        #expect(event.priority == .normal)
        #expect(event.source == .navigation)
        #expect(event.expiresAt == event.createdAt.addingTimeInterval(6))
        // once per trip, not per route version, so a reroute doesn't bring it back
        let startKey = try #require(await harness.engine.submitted.first?.dedupKey)
        #expect(event.dedupKey == String(startKey.dropLast("-v0-start".count)) + "-landmark-William Vernon Skiles Building")
    }

    @Test
    func signCVAlreadyReadOnlyConfirmsTheRoute() async throws {
        let howey = try building("Howey Building", along: 40, lateral: -20)
        let harness = try Harness(buildings: [howey])
        await harness.start()
        await harness.walk(from: 0, to: 30)
        let before = await harness.engine.submitted.count

        harness.landmarks.yield(sign("HOWEY", announced: true))

        #expect(await harness.engine.waitForCount(before + 1).last?.text == "You're on track.")
    }

    @Test
    func eachBuildingIsSpokenOnceAndOthersAreIgnored() async throws {
        let skiles = try building("Skiles", along: 50, lateral: 15)
        let howey = try building("Howey", along: 60, lateral: -15)
        let harness = try Harness(buildings: [skiles, howey])
        await harness.start()
        await harness.walk(from: 0, to: 30)
        let before = await harness.engine.submitted.count

        // handled in order, so the last one being spoken means the others were handled first
        for text in ["SKILES", "SKILES", "KLAUS", "HOWEY"] { harness.landmarks.yield(sign(text)) }
        let texts = await harness.engine.waitForCount(before + 2).dropFirst(before).map(\.text)

        #expect(texts == ["Passing Skiles on your right.", "Passing Howey on your left."])
    }

    @Test
    func pausedTripSaysNothingAndKeepsTheSignForLater() async throws {
        let skiles = try building("Skiles", along: 50, lateral: 15)
        let harness = try Harness(buildings: [skiles])
        await harness.start()
        await harness.walk(from: 0, to: 30)
        await harness.manager.pauseTrip()
        harness.landmarks.yield(sign("SKILES"))
        await harness.landmarks.waitUntilHandled()
        #expect(await harness.engine.texts.last == "Trip paused.")
        await harness.manager.resumeTrip()
        let before = await harness.engine.submitted.count

        harness.landmarks.yield(sign("SKILES"))
        let texts = await harness.engine.waitForCount(before + 1).map(\.text)

        #expect(texts.filter { $0.hasPrefix("Passing") } == ["Passing Skiles on your right."])
        #expect(texts.last == "Passing Skiles on your right.")
    }

    @Test
    func destinationSignConfirmsArrivalEvenAfterArriving() async throws {
        // the corner route ends 160 m along; the building is around the end of the route
        let price = try building("Price Gilbert Memorial Library", aliases: ["Library"], along: 160, lateral: 0,
                                 size: 20)
        let harness = try Harness(buildings: [price])
        await harness.start()
        await harness.walk(from: 0, to: 160)
        #expect(await harness.states.waitFor { $0.phase == .arrived }.phase == .arrived)
        let before = await harness.engine.submitted.count

        harness.landmarks.yield(sign("PRICE GILBERT LIBRARY"))

        #expect(await harness.engine.waitForCount(before + 1).last?.text
            == "This is Price Gilbert Memorial Library, your destination.")
    }

    @Test
    func doorNearTheEndIsGuidedTo() async throws {
        let harness = try Harness()
        await harness.start()
        await harness.walk(from: 0, to: 120)
        let door = LandmarkObservation(kind: .entrance, key: "door-7", bearing: RelativeBearing(degrees: -30),
                                       distance: 4, distanceAccuracy: .measured, confidence: 0.8)

        // 40 m left is too early; the same door at 26 m left is spoken
        harness.landmarks.yield(door)
        await harness.landmarks.waitUntilHandled()
        #expect(!(await harness.engine.texts.contains { $0.hasPrefix("Entrance") }))
        // the first walk's last fix was at 119 m; on at walking pace to 135.6 m, 24.4 m from the end
        await harness.walk(from: 120.4, to: 136)
        let before = await harness.engine.submitted.count
        harness.landmarks.yield(door)
        let event = try #require(await harness.engine.waitForCount(before + 1).last)

        #expect(event.text == "Entrance slightly left, 4 metres.")
        #expect(event.category == .landmark)
        #expect(event.dedupKey?.hasSuffix("-entrance-door-7") == true)
    }

    @Test
    func endedTripIgnoresSigns() async throws {
        let skiles = try building("Skiles", along: 50, lateral: 15)
        let harness = try Harness(buildings: [skiles])
        await harness.start()
        await harness.walk(from: 0, to: 30)
        await harness.manager.endTrip()
        let ended = await harness.engine.submitted.count

        // the ended trip's stream has no reader any more, so this is never spoken
        harness.landmarks.yield(sign("SKILES"))
        // a new trip matches afresh, on its own stream
        await harness.start()
        await harness.walk(from: 0, to: 30)
        harness.landmarks.yield(sign("SKILES"))
        let texts = await harness.engine.waitForCount(ended + 2).dropFirst(ended).map(\.text)

        #expect(texts.filter { $0.hasPrefix("Passing") } == ["Passing Skiles on your right."])
    }
}

// MARK: Directions

/// North 30 m, right onto Ferst Drive, then 60 m east: a first turn near enough to be said with the start.
private func shortFirstLegRoute() throws -> NavigationRoute {
    let start = GeoCoordinate(latitude: 33.775, longitude: -84.399)
    let corner = TripWalk.destination(from: start, bearing: 0, distance: 30)
    let end = TripWalk.destination(from: corner, bearing: 90, distance: 60)
    return try NavigationRoute(coordinates: [start, corner, end], steps: [
        RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Walk north.", spokenInstruction: "Walk north."),
        RouteStep(kind: .turnRight, coordinateIndex: 1, instruction: "Turn right onto Ferst Drive.",
                  spokenInstruction: "Turn right onto Ferst Drive."),
        RouteStep(kind: .arrive, coordinateIndex: 2, instruction: "Arrive", spokenInstruction: "You have arrived."),
    ], estimatedDuration: 75)
}

/// The heading that puts something due north in the middle of `direction`.
private func heading(withNorth direction: RelativeDirection) -> Double {
    GeoMath.normalizedBearing(-45 * Double(RelativeDirection.allCases.firstIndex(of: direction)!))
}

/// The corner route's heading at each distance along it.
private func cornerCourse(_ along: Double) -> Double {
    along < 100 ? 0 : 90
}

@Suite(.timeLimit(.minutes(1)))
struct TripManagerDirectionTests {
    @Test(arguments: [
        (RelativeDirection.ahead, "The path is ahead."),
        (.slightlyRight, "The path is slightly right."),
        (.right, "The path is on your right."),
        (.behindRight, "The path is behind you on your right."),
        (.behind, "Turn around, the path is behind you."),
        (.behindLeft, "The path is behind you on your left."),
        (.left, "The path is on your left."),
        (.slightlyLeft, "The path is slightly left."),
    ])
    func startSaysWhereThePathIsAndTheNearFirstTurn(_ direction: RelativeDirection, _ path: String) async throws {
        let harness = try Harness(route: try shortFirstLegRoute())
        await harness.start()
        await harness.waitForSleepers(2)
        // the path runs north from here
        await harness.fix(harness.point(0), course: heading(withNorth: direction))
        let start = try #require(await harness.engine.waitForCount(1).first)
        #expect(start.text == "Starting directions to Library, about 90 metres. \(path) "
            + "In about 30 metres, turn right onto Ferst Drive.")
    }

    @Test
    func startWithAnUnknownHeadingSaysTheFirstInstruction() async throws {
        let harness = try Harness(route: try shortFirstLegRoute())
        await harness.start()
        await harness.waitForSleepers(2)
        await harness.fix(harness.point(0))
        let start = try #require(await harness.engine.waitForCount(1).first)
        #expect(start.text == "Starting directions to Library, about 90 metres. \(setOff)"
            + " In about 30 metres, turn right onto Ferst Drive.")
    }

    @Test
    func startBeforeAnyFixUsesTheCompassFromTheRouteStart() async throws {
        let harness = try Harness()
        await harness.start()
        await harness.waitForSleepers(2)
        // standing still, facing south
        harness.location.headings.yield(HeadingSample(trueHeading: 180, magneticHeading: 184, accuracy: 10,
                                                      timestamp: harness.clock.now()))
        await harness.location.headings.waitUntilHandled()
        harness.clock.advance(by: 0.75)
        let start = try #require(await harness.engine.waitForCount(1).first)
        // the corner route's first turn is 100 m on, too far to say now
        #expect(start.text == "Starting directions to Library, about 160 metres. Turn around, the path is behind you.")
    }

    @Test(arguments: [
        (151.2, -20.0, "Arriving at Library. Library is on your left."),
        (151.2, 20, "Arriving at Library. Library is on your right."),
        (175, 0, "Arriving at Library. Library is ahead."),
        (135, 0, "Arriving at Library. Library is behind you."),
        // 1.8 m from the arriving fix, too near for a direction
        (153, 0, "Arriving at Library. Your destination is on the left."),
    ])
    func arrivalSaysWhereTheDestinationIsForAKnownHeading(_ along: Double, _ lateral: Double,
                                                          _ expected: String) async throws {
        let harness = try Harness()
        let destination = Destination(name: "Library", coordinate: harness.point(along, lateral: lateral))
        await harness.start(to: destination)
        // arrives at 151.2 m, walking east
        await harness.walk(from: 0, to: 160, course: cornerCourse)
        let texts = await harness.engine.texts
        #expect(texts.filter { $0.hasPrefix("Arriving") } == [expected])
    }

    @Test
    func arrivalWithAnUnknownHeadingSaysTheRoutesSide() async throws {
        let harness = try Harness()
        await harness.start(to: Destination(name: "Library", coordinate: harness.point(151.2, lateral: 20)))
        await harness.walk(from: 0, to: 160)
        let texts = await harness.engine.texts
        #expect(texts.filter { $0.hasPrefix("Arriving") } == ["Arriving at Library. Your destination is on the left."])
    }

    @Test(arguments: [
        (180.0, "You're walking away from the route. Turn around, the path is behind you."),
        (nil, "You seem to be walking away from the route. Turn around."),
    ])
    func wrongWaySaysWhereThePathIs(_ course: Double?, _ expected: String) async throws {
        let harness = try Harness()
        await harness.start()
        // the route starts north; walk 15.4 m south
        for index in 0...11 {
            await harness.fix(harness.point(-1.4 * Double(index)), course: course)
        }
        let texts = await harness.engine.texts
        #expect(texts.filter { $0.contains("walking away") } == [expected])
    }

    @Test(arguments: [
        // not which way to turn there: walking back reaches the corner from the other side
        (0.0, 5.0, "You may have passed the turn. It is behind you, about 20 metres away."),
        (nil, 5, "You may have passed the turn. Turn around and walk back about 20 metres."),
        // the corner is nearer than twice the accuracy, so it could lie either way
        (0, 15, "You may have passed the turn. Turn around and walk back about 20 metres."),
    ])
    func missedTurnWithNoRerouteSaysWhereTheTurnIs(_ course: Double?, _ accuracy: Double,
                                                   _ expected: String) async throws {
        let harness = try Harness()
        await harness.start()
        let facing: ((Double) -> Double)? = course.map { course in { _ in course } }
        await harness.walk(from: 0, to: 100, course: facing)
        // a failed reroute just before the corner holds the next one back, so the missed turn guides the way back
        await harness.manager.reroute()
        await waitUntil {
            await harness.engine.texts.contains("Couldn't get a new route. Keep following the current one.")
        }
        // straight on north past the corner, 1.4 m on from the last fix at 99.4 m
        let corner = harness.route.coordinates[1]
        for metres in TripWalk.distances(from: 1, to: 25) {
            await harness.fix(TripWalk.destination(from: corner, bearing: 0, distance: metres), accuracy: accuracy,
                              course: course)
        }
        let texts = await harness.engine.texts
        #expect(texts.filter { $0.hasPrefix("You may have passed the turn") } == [expected])
    }

    @Test(arguments: [
        // a cold-start fix may be anywhere within 40 m, so the path could lie either way
        (40, "Starting directions to Library, about 90 metres. \(setOff)"
            + " In about 30 metres, turn right onto Ferst Drive."),
        // looks 20 m ahead rather than 15, twice the accuracy
        (10, "Starting directions to Library, about 90 metres. Turn around, the path is behind you. "
            + "In about 30 metres, turn right onto Ferst Drive."),
    ] as [(Double, String)])
    func startSaysWhereThePathIsOnlyFromAPreciseFix(_ accuracy: Double, _ expected: String) async throws {
        let harness = try Harness(route: try shortFirstLegRoute())
        await harness.start()
        await harness.waitForSleepers(2)
        // standing still, facing south
        harness.location.headings.yield(HeadingSample(trueHeading: 180, magneticHeading: 184, accuracy: 10,
                                                      timestamp: harness.clock.now()))
        await harness.location.headings.waitUntilHandled()
        // a metre off the path, so the point 20 m on is clearly not nearer than twice the accuracy
        await harness.fix(harness.point(0, lateral: 1), accuracy: accuracy)
        let start = try #require(await harness.engine.waitForCount(1).first)
        #expect(start.text == expected)
    }

    @Test(arguments: [
        // the destination, about 20 m away, is nearer than twice the accuracy, so it could lie either way
        (12.0, "Arriving at Library. Your destination is on the left."),
        (5, "Arriving at Library. Library is on your left."),
    ])
    func arrivalSaysWhereTheDestinationIsOnlyBeyondTwiceTheAccuracy(_ accuracy: Double,
                                                                    _ expected: String) async throws {
        let harness = try Harness()
        await harness.start(to: Destination(name: "Library", coordinate: harness.point(151.2, lateral: -20)))
        await harness.walk(from: 0, to: 140, course: cornerCourse)
        for along in TripWalk.distances(from: 141.4, to: 160) {
            await harness.fix(harness.point(along), accuracy: accuracy, course: 90)
        }
        let texts = await harness.engine.texts
        #expect(texts.filter { $0.hasPrefix("Arriving") } == [expected])
    }

    @Test
    func aLateFixDoesNotReplaceANewerOne() async throws {
        let harness = try Harness(route: try shortFirstLegRoute())
        await harness.start()
        await harness.waitForSleepers(2)
        // standing still, facing south, with the path behind
        harness.location.headings.yield(HeadingSample(trueHeading: 180, magneticHeading: 184, accuracy: 10,
                                                      timestamp: harness.clock.now()))
        await harness.location.headings.waitUntilHandled()
        let now = harness.clock.now()
        await harness.fix(harness.point(0, lateral: 1), timestamp: now, then: 0)
        // older fixes arriving late, still recent enough to use: a rough one, then a precise one 40 m north, past
        // the corner, with the path ahead
        await harness.fix(harness.point(0), accuracy: 40, timestamp: now.addingTimeInterval(-3), then: 0)
        await harness.fix(TripWalk.destination(from: harness.point(0), bearing: 0, distance: 40),
                          timestamp: now.addingTimeInterval(-4), then: 0)
        harness.clock.advance(by: 0.75)
        let start = try #require(await harness.engine.waitForCount(1).first)
        #expect(start.text == "Starting directions to Library, about 90 metres. Turn around, the path is behind you. "
            + "In about 30 metres, turn right onto Ferst Drive.")
    }

    @Test(arguments: [
        (4.0, "Starting directions to Library, about 90 metres. Turn around, the path is behind you. "
            + "In about 30 metres, turn right onto Ferst Drive."),
        // the user may have walked on since
        (6, "Starting directions to Library, about 90 metres. \(setOff)"
            + " In about 30 metres, turn right onto Ferst Drive."),
    ] as [(Double, String)])
    func directionsNeedARecentFix(_ age: Double, _ expected: String) async throws {
        let harness = try Harness(route: try shortFirstLegRoute())
        await harness.start()
        await harness.waitForSleepers(2)
        harness.location.headings.yield(HeadingSample(trueHeading: 180, magneticHeading: 184, accuracy: 10,
                                                      timestamp: harness.clock.now()))
        await harness.location.headings.waitUntilHandled()
        // the start is spoken 0.75 s on, when the fix is that much older again
        await harness.fix(harness.point(0, lateral: 1),
                          timestamp: harness.clock.now().addingTimeInterval(0.75 - age), then: 0)
        harness.clock.advance(by: 0.75)
        let start = try #require(await harness.engine.waitForCount(1).first)
        #expect(start.text == expected)
    }

    @Test
    func startDoesNotWarnOfArrivingNearby() async throws {
        let start = GeoCoordinate(latitude: 33.775, longitude: -84.399)
        let route = try NavigationRoute(coordinates: [start, TripWalk.destination(from: start, bearing: 0, distance: 30)],
                                        steps: [
            RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Walk north.", spokenInstruction: "Walk north."),
            RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "You have arrived."),
        ], estimatedDuration: 25)
        let harness = try Harness(route: route)
        await harness.start()
        await harness.waitForSleepers(2)
        await harness.fix(harness.point(0), course: 0)
        let announcement = try #require(await harness.engine.waitForCount(1).first)
        #expect(announcement.text == "Starting directions to Library, about 30 metres. The path is ahead.")
    }
}

// MARK: Setting off

/// The corner route as Valhalla words it, naming the street and a compass direction.
private func namedCornerRoute() throws -> NavigationRoute {
    let route = try cornerRoute()
    return try NavigationRoute(coordinates: route.coordinates, steps: [
        RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Walk north on Ferst Drive.",
                  spokenInstruction: "Walk north on Ferst Drive. Then Turn right onto Atlantic Drive."),
        RouteStep(kind: .turnRight, coordinateIndex: 1, instruction: "Turn right onto Atlantic Drive.",
                  spokenInstruction: "Turn right onto Atlantic Drive."),
        RouteStep(kind: .arrive, coordinateIndex: 2, instruction: "Your destination is on the left.",
                  spokenInstruction: "Your destination is on the left."),
    ], estimatedDuration: 130)
}

/// A reroute answer from `origin`, east along Atlantic Drive, as Valhalla words it.
private func namedEastRoute(from origin: GeoCoordinate) throws -> NavigationRoute {
    try NavigationRoute(coordinates: [origin, TripWalk.destination(from: origin, bearing: 90, distance: 80)], steps: [
        RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Head east on Atlantic Drive.",
                  spokenInstruction: "Head east on Atlantic Drive."),
        RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "You have arrived."),
    ], estimatedDuration: 60)
}

private func namesACompassDirection(_ text: String) -> Bool {
    text.contains(/(?i)\b(?:north|south|east|west)(?:east|west)?\b/)
}

/// Every state the trip publishes, in order.
private final class StateLog: Sendable {
    private let states = Mutex<[TripState]>([])

    init(_ manager: TripManager) {
        let stream = manager.tripStates()
        Task { [self] in
            for await state in stream { states.withLock { $0.append(state) } }
        }
    }

    var instructions: [String] { states.withLock { $0.compactMap(\.nextManeuver?.instruction) } }
}

@Suite(.timeLimit(.minutes(1)))
struct TripManagerDepartureTests {
    @Test(arguments: [
        (true, "Starting directions to Library, about 160 metres. The path is ahead."),
        (false, "Starting directions to Library, about 160 metres. Follow Ferst Drive. "
            + "You'll be warned if it's the wrong way."),
    ])
    func startNamesTheStreetWithoutACompassDirection(_ facingNorth: Bool, _ expected: String) async throws {
        let harness = try Harness(route: try namedCornerRoute())
        await harness.start()
        await harness.waitForSleepers(2)
        if facingNorth {
            harness.location.headings.yield(HeadingSample(trueHeading: 0, magneticHeading: 4, accuracy: 10,
                                                          timestamp: harness.clock.now()))
            await harness.location.headings.waitUntilHandled()
        }
        harness.clock.advance(by: 0.75)
        let start = try #require(await harness.engine.waitForCount(1).first)
        #expect(start.text == expected)
    }

    @Test(arguments: [
        // walking west, away from the route, which heads east from here
        (270.0, "New route. Turn around, the path is behind you."),
        (nil, "New route. Follow Atlantic Drive. You'll be warned if it's the wrong way."),
    ] as [(Double?, String)])
    func newRouteSaysWhereThePathIsLikeTheStart(_ course: Double?, _ expected: String) async throws {
        let harness = try Harness(route: try namedCornerRoute(),
                                  reroutes: [.success(try namedEastRoute(from: harness0Origin))])
        await harness.start()
        await harness.walk(from: 0, to: 50)
        for index in 1...32 {
            await harness.fix(harness.point(49, lateral: -min(1.4 * Double(index), 40)), course: course)
        }
        await harness.router.waitForRequests(1)
        await harness.router.respond()
        await waitUntil { await harness.engine.texts.contains { $0.hasPrefix("New route.") } }
        #expect(await harness.engine.texts.filter { $0.hasPrefix("New route.") } == [expected])
    }

    // nothing said or shown names a compass direction: not the start, the next step, a new route, or its next step
    @Test(arguments: [nil, 270.0])
    func noCompassDirectionIsSaidOrShown(_ course: Double?) async throws {
        let harness = try Harness(route: try namedCornerRoute(),
                                  reroutes: [.success(try namedEastRoute(from: harness0Origin))])
        let states = StateLog(harness.manager)
        await harness.start()
        await harness.waitForSleepers(2)
        harness.clock.advance(by: 0.75)
        await harness.engine.waitForCount(1)
        await harness.walk(from: 0, to: 50, course: course.map { _ in { _ in 0 } })
        for index in 1...32 {
            await harness.fix(harness.point(49, lateral: -min(1.4 * Double(index), 40)), course: course)
        }
        await harness.router.waitForRequests(1)
        await harness.router.respond()
        await waitUntil { await harness.engine.texts.contains { $0.hasPrefix("New route.") } }
        for metres in TripWalk.distances(from: 0, to: 20) {
            await harness.fix(TripWalk.destination(from: harness0Origin, bearing: 90, distance: metres),
                              course: course.map { _ in 90 })
        }
        await harness.manager.endTrip()

        let texts = await harness.engine.texts
        #expect(texts.contains { $0.hasPrefix("Starting directions") })
        #expect(!texts.contains(where: namesACompassDirection), "\(texts)")
        let instructions = states.instructions
        #expect(instructions.contains("Turn right onto Atlantic Drive."))
        #expect(!instructions.contains(where: namesACompassDirection), "\(instructions)")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct TripManagerRecordingTests {
    @Test
    func recordsEachFixAndAnnouncementWhileOn() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TripManagerRecordingTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = TripRecorder(directory: directory)
        recorder.setEnabled(true)
        let harness = try Harness(recorder: recorder)
        await harness.start()
        await harness.walk(from: 0, to: 50)
        await harness.goOffRoute(at: 49)
        await harness.manager.endTrip()

        let url = try #require(try recorder.recordings().first)
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        let fixes = rows.filter { $0.hasPrefix("fix,") }
        // 36 fixes walking, 32 going off route
        #expect(fixes.count == 36 + 32)
        let offRoute = try #require(fixes.first { $0.contains(",offRoute,") })
        // off route, still before the corner at step 1, 40 m to the left
        #expect(offRoute.contains(",-40.0,1,1,offRoute,"))
        #expect(rows.contains {
            $0.hasPrefix("announcement,") && $0.hasSuffix(",You're off the route. Finding a new route.")
        })
        #expect(rows.last?.hasSuffix(",Trip ended.") == true)
        #expect(!recorder.isRecording)
    }

    @Test
    func recordsNothingWhileOff() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TripManagerRecordingTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = TripRecorder(directory: directory)
        let harness = try Harness(recorder: recorder)
        await harness.start()
        await harness.walk(from: 0, to: 20)
        await harness.manager.endTrip()

        let recordings = try recorder.recordings()
        #expect(recordings.isEmpty)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct TripManagerSavedTripTests {
    private func store() -> (store: SavedTripStore, cleanUp: () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TripManagerSavedTripTests-\(UUID())")
        return (SavedTripStore(fileURL: directory.appending(path: "SavedTrip.json")),
                { try? FileManager.default.removeItem(at: directory) })
    }

    @Test
    func savesWhenTheTripStartsAndEachTimeAStepIsPassed() async throws {
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let harness = try Harness(savedTrips: store)
        #expect(store.load() == nil)

        await harness.start()
        let started = try #require(store.load())
        #expect(started.destination == library)
        #expect(started.route == harness.route)
        #expect(started.passedSteps == 1)

        await harness.walk(from: 0, to: 120)
        #expect(try #require(store.load()).passedSteps == 2)
        #expect(try #require(store.load()).tripID == started.tripID)
        await harness.manager.endTrip()
    }

    @Test
    func deletesTheSavedTripWhenTheTripEnds() async throws {
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let harness = try Harness(savedTrips: store)
        await harness.start()
        await harness.walk(from: 0, to: 20)
        #expect(store.load() != nil)

        await harness.manager.endTrip()

        #expect(store.load() == nil)
    }

    @Test
    func deletesTheSavedTripOnArrival() async throws {
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let harness = try Harness(savedTrips: store)
        await harness.start()
        await harness.walk(from: 0, to: 160)
        #expect(await harness.states.waitFor { $0.phase == .arrived }.phase == .arrived)

        #expect(store.load() == nil)
        await harness.manager.endTrip()
    }
}
