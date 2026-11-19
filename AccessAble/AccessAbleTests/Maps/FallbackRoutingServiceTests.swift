import Foundation
import Testing
@testable import AccessAble

struct FallbackRoutingServiceTests {
    private static let origin = MapsSamples.origin
    private static let destination = MapsSamples.destination.coordinate

    /// A different route from `MapsSamples.route`, so tests can tell which service answered.
    private static let backupRoute = try! NavigationRoute(
        coordinates: [origin, GeoCoordinate(latitude: 33.7755, longitude: -84.3995), destination],
        steps: [
            RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Follow the path",
                      spokenInstruction: "Follow the path."),
            RouteStep(kind: .arrive, coordinateIndex: 2, instruction: "Arrive at the destination",
                      spokenInstruction: "You have arrived."),
        ],
        estimatedDuration: 100
    )

    /// Answers with `answer` and counts its calls. `hangs` waits until cancelled instead, like a dead server whose
    /// connection never times out on its own.
    private actor FakeRouting: RoutingService {
        enum Behaviour: Sendable {
            case returns(NavigationRoute)
            case fails(any Error)
            case hangs
        }

        private let behaviour: Behaviour
        private(set) var calls = 0
        private(set) var wasCancelled = false

        init(_ behaviour: Behaviour) {
            self.behaviour = behaviour
        }

        func route(
            from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
        ) async throws -> NavigationRoute {
            calls += 1
            switch behaviour {
            case .returns(let route):
                return route
            case .fails(let error):
                throw error
            case .hangs:
                do {
                    try await Task.sleep(for: .seconds(3600))
                } catch {
                    wasCancelled = true
                    throw CancellationError()
                }
                throw RoutingError.serverUnavailable
            }
        }
    }

    private actor RecordingSink: AnnouncementSink {
        private(set) var events: [AnnouncementEvent] = []
        func submit(_ event: AnnouncementEvent) async { events.append(event) }
    }

    private actor SleepRecorder {
        private(set) var durations: [Duration] = []
        func record(_ duration: Duration) { durations.append(duration) }
    }

    /// The timeout never fires, so only the primary's answer decides.
    private static let neverTimesOut: @Sendable (Duration) async throws -> Void = { _ in
        try await Task.sleep(for: .seconds(3600))
    }

    private func makeService(
        primary: FakeRouting, fallback: FakeRouting, sink: RecordingSink,
        sleep: @escaping @Sendable (Duration) async throws -> Void = FallbackRoutingServiceTests.neverTimesOut
    ) -> FallbackRoutingService {
        FallbackRoutingService(primary: primary, fallback: fallback, announcements: sink, sleep: sleep)
    }

    private func requestRoute(with service: some RoutingService) async throws -> NavigationRoute {
        try await service.route(from: Self.origin, to: Self.destination, options: RouteOptions())
    }

    // MARK: - Success

    @Test
    func returnsValhallaRouteWithoutAskingAppleOrTellingTheUser() async throws {
        let primary = FakeRouting(.returns(MapsSamples.route))
        let fallback = FakeRouting(.returns(Self.backupRoute))
        let sink = RecordingSink()

        let route = try await requestRoute(with: makeService(primary: primary, fallback: fallback, sink: sink))

        #expect(route == MapsSamples.route)
        #expect(await primary.calls == 1)
        #expect(await fallback.calls == 0)
        #expect(await sink.events.isEmpty)
    }

    // MARK: - Error

    @Test(arguments: [RoutingError.serverUnavailable, .invalidResponse, .noRouteFound])
    func fallsBackToAppleWhenValhallaFails(_ error: RoutingError) async throws {
        let primary = FakeRouting(.fails(error))
        let fallback = FakeRouting(.returns(Self.backupRoute))
        let sink = RecordingSink()

        let route = try await requestRoute(with: makeService(primary: primary, fallback: fallback, sink: sink))

        #expect(route == Self.backupRoute)
        #expect(await fallback.calls == 1)
        let events = await sink.events
        #expect(events.map(\.text) == ["Using backup directions. They may include stairs."])
        #expect(events.first?.category == .system)
        #expect(events.first?.priority == .high)
    }

    @Test
    func deadValhallaServerStillGivesARouteTheTripCanStart() async throws {
        let dead = ValhallaEndpoint(baseURL: URL(string: "https://dead.valhalla.invalid")!, userAgent: "tests")
        let valhalla = ValhallaRoutingService(endpoint: dead) { _ in throw URLError(.cannotConnectToHost) }
        let fallback = FakeRouting(.returns(Self.backupRoute))
        let sink = RecordingSink()
        let service = FallbackRoutingService(primary: valhalla, fallback: fallback, announcements: sink,
                                             sleep: Self.neverTimesOut)

        let route = try await requestRoute(with: service)

        #expect(route == Self.backupRoute)
        #expect(route.steps.first?.kind == .depart)
        #expect(route.steps.last?.kind == .arrive)
        #expect(await sink.events.map(\.text) == [FallbackRoutingService.backupNotice])
    }

    @Test
    func throwsWhenBothFailAndSaysNothing() async {
        let primary = FakeRouting(.fails(RoutingError.serverUnavailable))
        let fallback = FakeRouting(.fails(RoutingError.noRouteFound))
        let sink = RecordingSink()

        await #expect(throws: RoutingError.noRouteFound) {
            try await requestRoute(with: makeService(primary: primary, fallback: fallback, sink: sink))
        }
        #expect(await sink.events.isEmpty)
    }

    @Test
    func reportsUnavailableWhenBothServersAreDown() async {
        let primary = FakeRouting(.fails(RoutingError.serverUnavailable))
        let fallback = FakeRouting(.fails(URLError(.notConnectedToInternet)))
        let sink = RecordingSink()

        await #expect(throws: RoutingError.serverUnavailable) {
            try await requestRoute(with: makeService(primary: primary, fallback: fallback, sink: sink))
        }
    }

    @Test
    func cancellationIsPassedOnWithoutFallingBack() async {
        let primary = FakeRouting(.fails(CancellationError()))
        let fallback = FakeRouting(.returns(Self.backupRoute))
        let sink = RecordingSink()

        await #expect(throws: CancellationError.self) {
            try await requestRoute(with: makeService(primary: primary, fallback: fallback, sink: sink))
        }
        #expect(await fallback.calls == 0)
        #expect(await sink.events.isEmpty)
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
        let sink = RecordingSink()
        let sleeps = SleepRecorder()
        // the timeout fires at once instead of after six real seconds
        let service = makeService(primary: primary, fallback: fallback, sink: sink) { duration in
            await sleeps.record(duration)
        }

        let route = try await requestRoute(with: service)

        #expect(route == Self.backupRoute)
        #expect(await sleeps.durations == [.seconds(6)])
        #expect(await primary.wasCancelled)
        #expect(await fallback.calls == 1)
        #expect(await sink.events.map(\.text) == [FallbackRoutingService.backupNotice])
    }

    @Test
    func timeoutThenAppleFailureThrowsApplesError() async {
        let primary = FakeRouting(.hangs)
        let fallback = FakeRouting(.fails(RoutingError.serverUnavailable))
        let sink = RecordingSink()
        let service = makeService(primary: primary, fallback: fallback, sink: sink) { _ in }

        await #expect(throws: RoutingError.serverUnavailable) {
            try await requestRoute(with: service)
        }
        #expect(await sink.events.isEmpty)
    }
}
