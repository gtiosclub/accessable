import Foundation
import Testing
@testable import AccessAble

/// Answers each request as `behaviour` says for that call, numbered from 0, and records what it was asked. `hangs`
/// waits until cancelled instead, like a dead server whose connection never times out on its own.
private actor FakeRouting: RoutingService {
    enum Behaviour: Sendable {
        case returns(NavigationRoute)
        case fails(any Error)
        case hangs
    }

    private let behaviour: @Sendable (Int) -> Behaviour
    private(set) var receivedOptions: [RouteOptions] = []
    private(set) var cancellations = 0
    private var waiters: [(isMet: @Sendable (Int, Int) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    init(_ behaviour: Behaviour) {
        self.behaviour = { _ in behaviour }
    }

    init(byCall behaviour: @escaping @Sendable (Int) -> Behaviour) {
        self.behaviour = behaviour
    }

    var calls: Int { receivedOptions.count }

    func route(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async throws -> NavigationRoute {
        let call = receivedOptions.count
        receivedOptions.append(options)
        wakeWaiters()
        switch behaviour(call) {
        case .returns(let route):
            return route
        case .fails(let error):
            throw error
        case .hangs:
            do {
                // a clock no one advances, so only cancellation ends the wait
                try await ManualClock().sleep(for: .seconds(3600))
            } catch {
                cancellations += 1
                wakeWaiters()
                throw CancellationError()
            }
            throw RoutingError.serverUnavailable
        }
    }

    /// Returns once `count` requests have come.
    func waitForRequests(_ count: Int) async {
        await wait { calls, _ in calls >= count }
    }

    /// Returns once `count` hanging requests have been cancelled.
    func waitForCancellations(_ count: Int) async {
        await wait { _, cancellations in cancellations >= count }
    }

    private func wait(until isMet: @escaping @Sendable (Int, Int) -> Bool) async {
        guard !isMet(calls, cancellations) else { return }
        await withCheckedContinuation { waiters.append((isMet, $0)) }
    }

    private func wakeWaiters() {
        let met = waiters.filter { $0.isMet(calls, cancellations) }
        waiters.removeAll { $0.isMet(calls, cancellations) }
        for waiter in met { waiter.continuation.resume() }
    }
}

private actor FakeReports: ReportService {
    private let active: [Report]

    init(_ active: [Report]) {
        self.active = active
    }

    func submit(_ report: Report) async throws {}

    func reports(near coordinate: GeoCoordinate, radius: Double) async throws -> [Report] { active }

    nonisolated func reportChanges(near coordinate: GeoCoordinate, radius: Double) -> AsyncStream<[Report]> {
        AsyncStream { $0.finish() }
    }

    func confirm(_ reportID: String, isStillPresent: Bool, userID: String) async throws {}
}

@Suite(.timeLimit(.minutes(1)))
struct FallbackRoutingServiceTests {
    private static let origin = GeoCoordinate(latitude: 33.7750, longitude: -84.4000)
    private static let destination = GeoCoordinate(latitude: 33.7770, longitude: -84.3980)
    /// Where Apple's walk turns, about 140 m off the straight line between its ends.
    private static let corner = GeoCoordinate(latitude: 33.7750, longitude: -84.3980)
    private static let exclusions = RouteOptions(excludeLocations: [corner])

    private static let valhallaRoute = try! NavigationRoute(
        coordinates: [origin, GeoCoordinate(latitude: 33.7770, longitude: -84.4000), destination],
        steps: [
            RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Walk north.", spokenInstruction: "Walk north."),
            RouteStep(kind: .arrive, coordinateIndex: 2, instruction: "Arrive", spokenInstruction: "You have arrived."),
        ],
        estimatedDuration: 300
    )

    /// What Apple Maps answers: through `corner`, so it passes a report there.
    private static let backupRoute = try! NavigationRoute(
        appleMapsCoordinates: [origin, corner, destination],
        steps: [
            AppleMapsStep(instructions: "", start: origin),
            AppleMapsStep(instructions: "Turn left", start: corner),
            AppleMapsStep(instructions: "Arrive at the destination", start: destination),
        ],
        estimatedDuration: 300
    )

    private static let report = Report(
        id: "construction-1", kind: .construction, coordinate: corner,
        createdAt: .now, expiresAt: .now.addingTimeInterval(3600), reporterID: "user-1"
    )

    private func request(
        _ service: some RoutingService, options: RouteOptions = RouteOptions()
    ) -> Task<NavigationRoute, any Error> {
        Task { try await service.route(from: Self.origin, to: Self.destination, options: options) }
    }

    /// Lets `primary`'s request and the timeout begin, then moves `clock` past the timeout.
    private func timeOut(_ primary: FakeRouting, requests: Int = 1, on clock: ManualClock) async throws {
        await primary.waitForRequests(requests)
        try await clock.waitForSleepers(1)
        clock.advance(by: FallbackRoutingService.defaultTimeout)
    }

    // MARK: - Success

    @Test
    func returnsValhallaRouteWithoutAskingApple() async throws {
        let primary = FakeRouting(.returns(Self.valhallaRoute))
        let fallback = FakeRouting(.returns(Self.backupRoute))
        let service = FallbackRoutingService(primary: primary, fallback: fallback, clock: ManualClock())

        let route = try await request(service).value

        #expect(route == Self.valhallaRoute)
        #expect(route.source == .valhalla)
        #expect(await fallback.calls == 0)
    }

    // MARK: - Error

    @Test(arguments: [RoutingError.serverUnavailable, .invalidResponse, .noRouteFound, .exclusionsRejected])
    func fallsBackToAppleWhenValhallaFails(_ error: RoutingError) async throws {
        let primary = FakeRouting(.fails(error))
        let fallback = FakeRouting(.returns(Self.backupRoute))
        let service = FallbackRoutingService(primary: primary, fallback: fallback, clock: ManualClock())

        let route = try await request(service).value

        #expect(route == Self.backupRoute)
        #expect(route.source == .appleMaps)
        #expect(await fallback.receivedOptions == [RouteOptions()])
    }

    @Test
    func deadValhallaServerStillGivesARouteTheTripCanStart() async throws {
        let dead = ValhallaEndpoint(baseURL: URL(string: "https://dead.valhalla.invalid")!, userAgent: "tests")
        let valhalla = ValhallaRoutingService(endpoint: dead) { _ in throw URLError(.cannotConnectToHost) }
        let fallback = FakeRouting(.returns(Self.backupRoute))
        let service = FallbackRoutingService(primary: valhalla, fallback: fallback, clock: ManualClock())

        let route = try await request(service).value

        #expect(route.source == .appleMaps)
        #expect(route.steps.first?.kind == .depart)
        #expect(route.steps.last?.kind == .arrive)
    }

    @Test
    func noRouteFromEitherWins() async {
        let primary = FakeRouting(.fails(RoutingError.serverUnavailable))
        let fallback = FakeRouting(.fails(RoutingError.noRouteFound))
        let service = FallbackRoutingService(primary: primary, fallback: fallback, clock: ManualClock())

        await #expect(throws: RoutingError.noRouteFound) { try await request(service).value }
    }

    @Test
    func rejectedExclusionsAreKeptWhenAppleFailsToo() async {
        let primary = FakeRouting(.fails(RoutingError.exclusionsRejected))
        let fallback = FakeRouting(.fails(RoutingError.serverUnavailable))
        let service = FallbackRoutingService(primary: primary, fallback: fallback, clock: ManualClock())

        await #expect(throws: RoutingError.exclusionsRejected) { try await request(service).value }
    }

    @Test
    func reportsUnavailableWhenBothServersAreDown() async {
        let primary = FakeRouting(.fails(RoutingError.serverUnavailable))
        let fallback = FakeRouting(.fails(URLError(.notConnectedToInternet)))
        let service = FallbackRoutingService(primary: primary, fallback: fallback, clock: ManualClock())

        await #expect(throws: RoutingError.serverUnavailable) { try await request(service).value }
    }

    // MARK: - Exclusions, which Apple Maps can't honour

    @Test(arguments: [
        (RoutingError.serverUnavailable, RoutingError.exclusionsRejected),
        (.invalidResponse, .exclusionsRejected),
        (.exclusionsRejected, .exclusionsRejected),
        (.noRouteFound, .noRouteFound),
    ])
    func neverAsksAppleToAvoidPlaces(_ error: RoutingError, _ expected: RoutingError) async {
        let primary = FakeRouting(.fails(error))
        let fallback = FakeRouting(.returns(Self.backupRoute))
        let service = FallbackRoutingService(primary: primary, fallback: fallback, clock: ManualClock())

        await #expect(throws: expected) { try await request(service, options: Self.exclusions).value }
        #expect(await fallback.calls == 0)
    }

    @Test
    func aTimeoutWithExclusionsRejectsThemAndIsNotRemembered() async throws {
        let primary = FakeRouting(byCall: { $0 == 0 ? .hangs : .returns(Self.valhallaRoute) })
        let fallback = FakeRouting(.returns(Self.backupRoute))
        let clock = ManualClock()
        let service = FallbackRoutingService(primary: primary, fallback: fallback, clock: clock)

        let routing = request(service, options: Self.exclusions)
        try await timeOut(primary, on: clock)

        await #expect(throws: RoutingError.exclusionsRejected) { try await routing.value }
        await primary.waitForCancellations(1)
        #expect(await fallback.calls == 0)
        // a slow request with exclusions says nothing of Valhalla without them
        #expect(try await request(service).value == Self.valhallaRoute)
    }

    @Test
    func appleMapsRefusesToRouteAroundPlaces() async {
        await #expect(throws: RoutingError.exclusionsRejected) {
            try await AppleMapsRoutingService().route(from: Self.origin, to: Self.destination,
                                                      options: Self.exclusions)
        }
    }

    // MARK: - Timeout

    @Test
    func defaultTimeoutIsSixSeconds() {
        #expect(FallbackRoutingService.defaultTimeout == .seconds(6))
    }

    @Test
    func fallsBackToAppleWhenValhallaTakesTooLong() async throws {
        let primary = FakeRouting(.hangs)
        let fallback = FakeRouting(.returns(Self.backupRoute))
        let clock = ManualClock()
        let service = FallbackRoutingService(primary: primary, fallback: fallback, clock: clock)

        let routing = request(service)
        try await timeOut(primary, on: clock)

        #expect(try await routing.value == Self.backupRoute)
        await primary.waitForCancellations(1)
        #expect(await fallback.calls == 1)
    }

    @Test
    func timeoutThenAppleFailureThrowsApplesError() async throws {
        let primary = FakeRouting(.hangs)
        let fallback = FakeRouting(.fails(RoutingError.serverUnavailable))
        let clock = ManualClock()
        let service = FallbackRoutingService(primary: primary, fallback: fallback, clock: clock)

        let routing = request(service)
        try await timeOut(primary, on: clock)

        await #expect(throws: RoutingError.serverUnavailable) { try await routing.value }
    }

    @Test
    func afterATimeoutAsksAppleStraightAwayForTwoMinutes() async throws {
        let primary = FakeRouting(byCall: { $0 == 0 ? .hangs : .returns(Self.valhallaRoute) })
        let fallback = FakeRouting(.returns(Self.backupRoute))
        let clock = ManualClock()
        let service = FallbackRoutingService(primary: primary, fallback: fallback, clock: clock)
        let first = request(service)
        try await timeOut(primary, on: clock)
        _ = try await first.value

        clock.advance(by: FallbackRoutingService.timeoutMemory - .seconds(1))
        #expect(try await request(service).value == Self.backupRoute)
        #expect(await primary.calls == 1)
        // asked to avoid places, Valhalla is still the only one that can
        #expect(try await request(service, options: Self.exclusions).value == Self.valhallaRoute)
        #expect(await primary.calls == 2)

        clock.advance(by: .seconds(1))
        #expect(try await request(service).value == Self.valhallaRoute)
        #expect(await primary.calls == 3)
        #expect(await fallback.calls == 2)
    }

    @Test
    func cancellingTheCallerDuringTheRaceCancelsValhallaAndNeverAsksApple() async throws {
        let primary = FakeRouting(.hangs)
        let fallback = FakeRouting(.returns(Self.backupRoute))
        let clock = ManualClock()
        let service = FallbackRoutingService(primary: primary, fallback: fallback, clock: clock)

        let routing = request(service)
        await primary.waitForRequests(1)
        try await clock.waitForSleepers(1)
        routing.cancel()

        await #expect(throws: CancellationError.self) { try await routing.value }
        await primary.waitForCancellations(1)
        #expect(await fallback.calls == 0)
    }

    // MARK: - Inside report-aware routing

    /// However Valhalla fails, report-aware routing ends on a route from Apple Maps that still warns of the report
    /// it passes, and Apple Maps is never asked to avoid it. A nil error is a timeout.
    @Test(arguments: [RoutingError.serverUnavailable, .noRouteFound, .exclusionsRejected, nil])
    func reportAwareRoutingWarnsOfReportsOnAnAppleRoute(_ error: RoutingError?) async throws {
        let valhalla = FakeRouting(error.map { .fails($0) } ?? .hangs)
        let apple = FakeRouting(.returns(Self.backupRoute))
        let timeoutClock = ManualClock()
        let spacingClock = ManualClock()
        let service = ReportAwareRoutingService(
            base: FallbackRoutingService(primary: valhalla, fallback: apple, clock: timeoutClock),
            reports: FakeReports([Self.report]), clock: spacingClock
        )
        let hangs = error == nil

        let routing = request(service)
        if hangs { try await timeOut(valhalla, on: timeoutClock) }
        await valhalla.waitForRequests(1)
        try await spacingClock.waitForSleepers(1)
        spacingClock.advance(by: ReportAwareRoutingService.retrySpacing)
        if hangs { try await timeOut(valhalla, requests: 2, on: timeoutClock) }
        let route = try await routing.value

        #expect(route.source == .appleMaps)
        #expect(route.unavoidedReports.map(\.id) == [Self.report.id])
        #expect(await valhalla.receivedOptions.map(\.excludeLocations) == [[Self.corner], []])
        #expect(await apple.receivedOptions == [RouteOptions()])
    }
}
