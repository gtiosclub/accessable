import Foundation
import Testing
@testable import AccessAble

private actor ReportRoutingServiceFake: ReportService {
    private var stored: [Report]
    private nonisolated let changes = Broadcaster<[Report]>(replaysLatest: true)

    init(_ stored: [Report]) {
        self.stored = stored
        changes.send(stored)
    }

    func submit(_ report: Report) async throws {
        stored.removeAll { $0.id == report.id }
        stored.append(report)
        changes.send(stored)
    }

    func reports(
        near coordinate: GeoCoordinate,
        radius: Double
    ) async throws -> [Report] {
        stored
    }

    nonisolated func reportChanges(
        near coordinate: GeoCoordinate,
        radius: Double
    ) -> AsyncStream<[Report]> {
        changes.stream()
    }

    func confirm(
        _ reportID: String,
        isStillPresent: Bool,
        userID: String
    ) async throws {}
}

private actor RoutingServiceFake: RoutingService {
    private var outcomes: [Result<NavigationRoute, RoutingError>]
    private(set) var receivedOptions: [RouteOptions] = []

    init(_ outcomes: [Result<NavigationRoute, RoutingError>]) {
        self.outcomes = outcomes
    }

    func route(
        from origin: GeoCoordinate,
        to destination: GeoCoordinate,
        options: RouteOptions
    ) async throws -> NavigationRoute {
        receivedOptions.append(options)
        guard !outcomes.isEmpty else {
            throw RoutingError.serverUnavailable
        }
        return try outcomes.removeFirst().get()
    }
}

struct ReportAwareRoutingServiceTests {
    private let origin = GeoCoordinate(latitude: 33.775, longitude: -84.399)
    private let destination = GeoCoordinate(latitude: 33.7756, longitude: -84.4038)

    private func route() throws -> NavigationRoute {
        try NavigationRoute(
            coordinates: [origin, destination],
            steps: [
                RouteStep(kind: .depart, coordinateIndex: 0,
                          instruction: "Start", spokenInstruction: "Start"),
                RouteStep(kind: .arrive, coordinateIndex: 1,
                          instruction: "Arrive", spokenInstruction: "Arrive")
            ],
            estimatedDuration: 60
        )
    }

    private func report() -> Report {
        Report(
            id: "construction-1",
            kind: .construction,
            coordinate: GeoCoordinate(latitude: 33.7753, longitude: -84.4014),
            createdAt: .now,
            expiresAt: .now.addingTimeInterval(3600),
            reporterID: "user-1"
        )
    }

    @Test
    func sendsPointExclusionsAndMarksReportsAvoided() async throws {
        let report = report()
        let base = RoutingServiceFake([.success(try route())])
        let service = ReportAwareRoutingService(
            base: base,
            reports: ReportRoutingServiceFake([report])
        )

        let actual = try await service.route(
            from: origin,
            to: destination,
            options: RouteOptions()
        )
        let options = await base.receivedOptions

        #expect(options.count == 1)
        #expect(options[0].excludeLocations == [report.coordinate])
        #expect(options[0].excludePolygons.isEmpty)
        #expect(actual.avoidedReports == [report])
        #expect(actual.unavoidedReports.isEmpty)
    }

    @Test
    func retriesWithoutExclusionsWhenValhallaCannotFindRoute() async throws {
        let report = report()
        let base = RoutingServiceFake([
            .failure(.noRouteFound),
            .success(try route())
        ])
        let service = ReportAwareRoutingService(
            base: base,
            reports: ReportRoutingServiceFake([report])
        )

        let actual = try await service.route(
            from: origin,
            to: destination,
            options: RouteOptions()
        )
        let options = await base.receivedOptions

        #expect(options.count == 2)
        #expect(!options[0].excludeLocations.isEmpty)
        #expect(options[1].excludeLocations.isEmpty)
        #expect(actual.unavoidedReports == [report])
    }

    @Test
    func ignoresExpiredReports() async throws {
        var expired = report()
        expired.expiresAt = .now.addingTimeInterval(-1)
        let base = RoutingServiceFake([.success(try route())])
        let service = ReportAwareRoutingService(
            base: base,
            reports: ReportRoutingServiceFake([expired])
        )

        let actual = try await service.route(
            from: origin,
            to: destination,
            options: RouteOptions()
        )
        let options = await base.receivedOptions

        #expect(options.count == 1)
        #expect(options[0].excludeLocations.isEmpty)
        #expect(actual.avoidedReports.isEmpty)
    }
}
