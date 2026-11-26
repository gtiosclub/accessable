import Foundation
import Testing
@testable import AccessAble

private actor ReportRoutingServiceFake: ReportService {
    enum Fetch {
        case reports([Report])
        case failure(any Error)
        /// Never answers unless cancelled.
        case hang
    }

    private let fetch: Fetch
    private(set) var fetchCount = 0

    init(_ fetch: Fetch) {
        self.fetch = fetch
    }

    func submit(_ report: Report) async throws {}

    func reports(
        near coordinate: GeoCoordinate,
        radius: Double
    ) async throws -> [Report] {
        fetchCount += 1
        switch fetch {
        case .reports(let reports): return reports
        case .failure(let error): throw error
        case .hang:
            // A clock no one advances, so only cancellation ends the wait.
            try await ManualClock().sleep(for: .seconds(3600))
            return []
        }
    }

    nonisolated func reportChanges(
        near coordinate: GeoCoordinate,
        radius: Double
    ) -> AsyncStream<[Report]> {
        AsyncStream { $0.finish() }
    }

    func confirm(_ reportID: String, isStillPresent: Bool) async throws -> Bool { false }
}

private actor RoutingServiceFake: RoutingService {
    private var outcomes: [Result<NavigationRoute, RoutingError>]
    private(set) var receivedOptions: [RouteOptions] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(_ outcomes: [Result<NavigationRoute, RoutingError>]) {
        self.outcomes = outcomes
    }

    func route(
        from origin: GeoCoordinate,
        to destination: GeoCoordinate,
        options: RouteOptions
    ) async throws -> NavigationRoute {
        receivedOptions.append(options)
        let count = receivedOptions.count
        for waiter in waiters where waiter.count <= count { waiter.continuation.resume() }
        waiters.removeAll { $0.count <= count }
        guard !outcomes.isEmpty else {
            throw RoutingError.serverUnavailable
        }
        return try outcomes.removeFirst().get()
    }

    /// Returns once `count` requests have come.
    func waitForRequests(_ count: Int) async {
        guard receivedOptions.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ReportAwareRoutingServiceTests {
    private struct Boom: Error {}

    private let origin = GeoCoordinate(latitude: 33.7750, longitude: -84.4000)
    private let destination = GeoCoordinate(latitude: 33.7770, longitude: -84.3980)
    /// Where the walk turns: about 140 m off the straight line between its ends.
    private let corner = GeoCoordinate(latitude: 33.7750, longitude: -84.3980)
    /// The other way round the block, about 185 m from `corner`.
    private let otherCorner = GeoCoordinate(latitude: 33.7770, longitude: -84.4000)

    private func route(via turn: GeoCoordinate) throws -> NavigationRoute {
        try NavigationRoute(
            coordinates: [origin, turn, destination],
            steps: [
                RouteStep(kind: .depart, coordinateIndex: 0,
                          instruction: "Start", spokenInstruction: "Start"),
                RouteStep(kind: .arrive, coordinateIndex: 2,
                          instruction: "Arrive", spokenInstruction: "Arrive")
            ],
            estimatedDuration: 300
        )
    }

    private func report(_ id: String = "construction-1", at coordinate: GeoCoordinate,
                        area: [GeoCoordinate]? = nil) -> Report {
        Report(
            id: id,
            kind: .construction,
            coordinate: coordinate,
            area: area,
            createdAt: .now,
            expiresAt: .now.addingTimeInterval(3600),
            reporterID: "user-1"
        )
    }

    /// Routes, moving `clock` past the spacing before each of `retries` retries.
    private func route(
        with service: ReportAwareRoutingService,
        base: RoutingServiceFake,
        clock: ManualClock,
        retries: Int = 0,
        options: RouteOptions = RouteOptions()
    ) async throws -> NavigationRoute {
        let routing = Task { [origin, destination] in
            try await service.route(from: origin, to: destination, options: options)
        }
        for attempt in 0..<retries {
            await base.waitForRequests(attempt + 1)
            try await clock.waitForSleepers(1)
            clock.advance(by: ReportAwareRoutingService.retrySpacing)
        }
        return try await routing.value
    }

    private func service(
        _ fetch: ReportRoutingServiceFake.Fetch, base: RoutingServiceFake, clock: ManualClock
    ) -> ReportAwareRoutingService {
        ReportAwareRoutingService(base: base, reports: ReportRoutingServiceFake(fetch), clock: clock)
    }

    @Test
    func excludesAReportOnABendingRoute() async throws {
        let report = report(at: corner)
        let base = RoutingServiceFake([.success(try route(via: otherCorner))])
        let clock = ManualClock()

        let actual = try await route(with: service(.reports([report]), base: base, clock: clock), base: base,
                                     clock: clock)

        let options = await base.receivedOptions
        #expect(options.count == 1)
        #expect(options[0].excludeLocations == [report.coordinate])
        #expect(options[0].excludePolygons.isEmpty)
        #expect(actual.unavoidedReports.isEmpty)
    }

    /// REPORT-6's objective: a report voted gone ends now, and the next route no longer goes around it.
    @Test
    func aReportVotedGoneNoLongerShapesTheRoute() async throws {
        let reports = PlaceholderReportService()
        var denied = report(at: corner)
        // old enough for a "no", with one already
        denied.createdAt = .now.addingTimeInterval(-3600)
        denied.negativesSinceConfirm = 1
        try await reports.submit(denied)
        let base = RoutingServiceFake([.success(try route(via: otherCorner)), .success(try route(via: corner))])
        let clock = ManualClock()
        let service = ReportAwareRoutingService(base: base, reports: reports, clock: clock)
        _ = try await route(with: service, base: base, clock: clock)

        try await reports.confirm(denied.id, isStillPresent: false)
        let after = try await route(with: service, base: base, clock: clock)

        let options = await base.receivedOptions
        #expect(options.map(\.excludeLocations) == [[corner], []])
        #expect(after.unavoidedReports.isEmpty)
    }

    @Test
    func excludesAReportedAreaAsAPolygon() async throws {
        let area = [
            GeoCoordinate(latitude: 33.7759, longitude: -84.3991),
            GeoCoordinate(latitude: 33.7761, longitude: -84.3991),
            GeoCoordinate(latitude: 33.7761, longitude: -84.3989),
        ]
        let base = RoutingServiceFake([.success(try route(via: corner))])
        let clock = ManualClock()

        _ = try await route(with: service(.reports([report(at: area[0], area: area)]), base: base, clock: clock),
                            base: base, clock: clock)

        let options = await base.receivedOptions
        #expect(options.map(\.excludePolygons) == [[area]])
        #expect(options[0].excludeLocations.isEmpty)
    }

    @Test(arguments: [ReportServiceError.notSignedIn, ReportServiceError.permissionDenied])
    func routesWithoutReportsWhenTheyCantBeFetched(_ error: ReportServiceError) async throws {
        let base = RoutingServiceFake([.success(try route(via: corner))])
        let clock = ManualClock()
        let own = RouteOptions(walkingSpeed: 0.8, excludeLocations: [corner])

        _ = try await route(with: service(.failure(error), base: base, clock: clock), base: base, clock: clock,
                            options: own)

        #expect(await base.receivedOptions == [own])
    }

    @Test
    func routesWithoutReportsWhenTheyDontArriveInTime() async throws {
        let base = RoutingServiceFake([.success(try route(via: corner))])
        let clock = ManualClock()
        let service = service(.hang, base: base, clock: clock)
        let routing = Task { [origin, destination] in
            try await service.route(from: origin, to: destination, options: RouteOptions())
        }
        try await clock.waitForSleepers(1)

        clock.advance(by: ReportAwareRoutingService.reportTimeout)

        _ = try await routing.value
        #expect(await base.receivedOptions == [RouteOptions()])
    }

    @Test
    func cancellingWhileReportsAreFetchedStopsTheRoute() async throws {
        let base = RoutingServiceFake([.success(try route(via: corner))])
        let clock = ManualClock()
        let service = service(.hang, base: base, clock: clock)
        let routing = Task { [origin, destination] in
            try await service.route(from: origin, to: destination, options: RouteOptions())
        }
        try await clock.waitForSleepers(1)

        routing.cancel()

        await #expect(throws: CancellationError.self) { try await routing.value }
        #expect(await base.receivedOptions.isEmpty)
    }

    @Test
    func skipsReportsForATripThatGoesNowhere() async throws {
        let base = RoutingServiceFake([.success(try route(via: corner))])
        let reports = ReportRoutingServiceFake(.reports([report(at: corner)]))
        let service = ReportAwareRoutingService(base: base, reports: reports, clock: ManualClock())

        _ = try await service.route(from: origin, to: origin, options: RouteOptions())

        #expect(await reports.fetchCount == 0)
        #expect(await base.receivedOptions == [RouteOptions()])
    }

    @Test(arguments: [RoutingError.noRouteFound, .exclusionsRejected])
    func retriesWithoutReportsWhenValhallaCantUseThem(_ error: RoutingError) async throws {
        let report = report(at: corner)
        let base = RoutingServiceFake([.failure(error), .success(try route(via: corner))])
        let clock = ManualClock()
        let own = RouteOptions(walkingSpeed: 0.8, excludeLocations: [otherCorner])

        let actual = try await route(with: service(.reports([report]), base: base, clock: clock), base: base,
                                     clock: clock, retries: 1, options: own)

        let options = await base.receivedOptions
        #expect(options.map(\.excludeLocations) == [[otherCorner, corner], [otherCorner]])
        #expect(options.allSatisfy { $0.walkingSpeed == 0.8 })
        #expect(actual.unavoidedReports == [report])
    }

    /// Only the reports the fallback route actually passes are warned about.
    @Test
    func aFallbackRouteAwayFromTheReportPassesNone() async throws {
        let base = RoutingServiceFake([.failure(.noRouteFound), .success(try route(via: otherCorner))])
        let clock = ManualClock()

        let actual = try await route(with: service(.reports([report(at: corner)]), base: base, clock: clock),
                                     base: base, clock: clock, retries: 1)

        #expect(await base.receivedOptions.count == 2)
        #expect(actual.unavoidedReports.isEmpty)
    }

    @Test(arguments: [RoutingError.serverUnavailable, .invalidResponse])
    func doesNotRetryOtherFailures(_ error: RoutingError) async throws {
        let base = RoutingServiceFake([.failure(error), .success(try route(via: corner))])
        let clock = ManualClock()

        await #expect(throws: error) {
            try await route(with: service(.reports([report(at: corner)]), base: base, clock: clock), base: base,
                            clock: clock)
        }
        #expect(await base.receivedOptions.count == 1)
    }

    /// A report at the user's own position can't be routed around, so it goes before the others.
    @Test
    func dropsReportsAtEitherEndBeforeTheRest() async throws {
        let atStart = report("start", at: GeoCoordinate(latitude: 33.775013, longitude: -84.4000))
        let onTheWay = report("corner", at: corner)
        let base = RoutingServiceFake([
            .failure(.noRouteFound), .failure(.noRouteFound), .success(try route(via: corner))
        ])
        let clock = ManualClock()

        let actual = try await route(with: service(.reports([atStart, onTheWay]), base: base, clock: clock),
                                     base: base, clock: clock, retries: 2)

        let options = await base.receivedOptions
        #expect(options.map { Set($0.excludeLocations) } == [
            [atStart.coordinate, onTheWay.coordinate], [onTheWay.coordinate], []
        ])
        #expect(Set(actual.unavoidedReports) == [atStart, onTheWay])
    }

    /// A report the trip just found ahead is avoided even when the fetch fails, and through the same fallback.
    @Test
    func givenReportsAreRoutedAroundWhenTheFetchFails() async throws {
        let given = report("given", at: corner)
        let base = RoutingServiceFake([.failure(.noRouteFound), .success(try route(via: corner))])
        let clock = ManualClock()

        let actual = try await route(with: service(.failure(ReportServiceError.notSignedIn), base: base, clock: clock),
                                     base: base, clock: clock, retries: 1, options: RouteOptions(reports: [given]))

        #expect(await base.receivedOptions == [RouteOptions(excludeLocations: [corner]), RouteOptions()])
        #expect(actual.unavoidedReports == [given])
    }

    @Test
    func givenReportsJoinTheFetchedOnesOnce() async throws {
        let onTheWay = GeoCoordinate(latitude: 33.7760, longitude: -84.3980)
        let fetched = report("both", at: corner)
        let given = [report("both", at: corner), report("given", at: onTheWay)]
        let base = RoutingServiceFake([.success(try route(via: otherCorner))])
        let clock = ManualClock()

        _ = try await route(with: service(.reports([fetched]), base: base, clock: clock), base: base, clock: clock,
                            options: RouteOptions(reports: given))

        let options = await base.receivedOptions
        #expect(options.count == 1)
        #expect(options[0].excludeLocations.count == 2)
        #expect(Set(options[0].excludeLocations) == [corner, onTheWay])
        #expect(options[0].reports.isEmpty)
    }

    @Test
    func waitsBetweenAttempts() async throws {
        let base = RoutingServiceFake([.failure(.noRouteFound), .success(try route(via: corner))])
        let clock = ManualClock()
        let service = service(.reports([report(at: corner)]), base: base, clock: clock)
        let routing = Task { [origin, destination] in
            try await service.route(from: origin, to: destination, options: RouteOptions())
        }
        await base.waitForRequests(1)
        try await clock.waitForSleepers(1)

        clock.advance(by: ReportAwareRoutingService.retrySpacing - .milliseconds(1))
        #expect(await base.receivedOptions.count == 1)
        clock.advance(by: .milliseconds(1))

        _ = try await routing.value
        #expect(await base.receivedOptions.count == 2)
    }
}
