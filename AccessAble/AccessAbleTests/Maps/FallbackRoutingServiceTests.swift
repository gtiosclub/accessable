import Foundation
import Synchronization
import Testing
@testable import AccessAble

/// Answers with `result` and records that it was asked, in order, into `calls` under its name.
private struct FakeRouter: RoutingService {
    let name: String
    let result: Result<NavigationRoute, RoutingError>
    let calls: CallLog

    func route(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async throws -> NavigationRoute {
        calls.record(name)
        return try result.get()
    }
}

private final class CallLog: Sendable {
    private let names = Mutex<[String]>([])
    func record(_ name: String) { names.withLock { $0.append(name) } }
    var values: [String] { names.withLock { $0 } }
}

private let origin = GeoCoordinate(latitude: 33.775, longitude: -84.399)
private let destination = GeoCoordinate(latitude: 33.776, longitude: -84.399)

private func router(_ name: String, _ result: Result<NavigationRoute, RoutingError>, _ calls: CallLog) -> FakeRouter {
    FakeRouter(name: name, result: result, calls: calls)
}

struct FallbackRoutingServiceTests {
    private func route(duration: Double) throws -> NavigationRoute {
        try NavigationRoute(coordinates: [origin, destination], steps: [
            RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Go", spokenInstruction: "Go"),
            RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "Arrive"),
        ], estimatedDuration: duration)
    }

    @Test
    func usesTheFirstServiceWhenItAnswers() async throws {
        let calls = CallLog()
        let service = FallbackRoutingService([
            router("stadia", .success(try route(duration: 1)), calls),
            router("fossgis", .success(try route(duration: 2)), calls),
            router("apple", .success(try route(duration: 3)), calls),
        ])

        let found = try await service.route(from: origin, to: destination, options: RouteOptions())

        #expect(found.estimatedDuration == 1)
        #expect(calls.values == ["stadia"])
    }

    @Test
    func triesStadiaThenFOSSGISThenApple() async throws {
        let calls = CallLog()
        let service = FallbackRoutingService([
            router("stadia", .failure(.serverUnavailable), calls),
            router("fossgis", .failure(.invalidResponse), calls),
            router("apple", .success(try route(duration: 3)), calls),
        ])

        let found = try await service.route(from: origin, to: destination, options: RouteOptions())

        #expect(found.estimatedDuration == 3)
        #expect(calls.values == ["stadia", "fossgis", "apple"])
    }

    @Test
    func stopsAtTheFirstServiceThatAnswersAfterAFailure() async throws {
        let calls = CallLog()
        let service = FallbackRoutingService([
            router("stadia", .failure(.serverUnavailable), calls),
            router("fossgis", .success(try route(duration: 2)), calls),
            router("apple", .success(try route(duration: 3)), calls),
        ])

        let found = try await service.route(from: origin, to: destination, options: RouteOptions())

        #expect(found.estimatedDuration == 2)
        #expect(calls.values == ["stadia", "fossgis"])
    }

    @Test
    func throwsTheLastErrorWhenEveryServiceFails() async {
        let calls = CallLog()
        let service = FallbackRoutingService([
            router("stadia", .failure(.serverUnavailable), calls),
            router("fossgis", .failure(.serverUnavailable), calls),
            router("apple", .failure(.noRouteFound), calls),
        ])

        await #expect(throws: RoutingError.noRouteFound) {
            try await service.route(from: origin, to: destination, options: RouteOptions())
        }
        #expect(calls.values == ["stadia", "fossgis", "apple"])
    }

    @Test
    func configuredChainAsksStadiaThenFOSSGISThenApple() async throws {
        let hosts = CallLog()
        let service = FallbackRoutingService.configured(
            stadiaAPIKey: "key-123",
            backup: router("apple", .success(try route(duration: 3)), hosts),
            send: { request in
                hosts.record(request.url?.host() ?? "")
                throw URLError(.notConnectedToInternet)
            }
        )

        let found = try await service.route(from: origin, to: destination, options: RouteOptions())

        #expect(found.estimatedDuration == 3)
        #expect(hosts.values == ["api.stadiamaps.com", "valhalla1.openstreetmap.de", "apple"])
    }

    @Test
    func configuredChainSkipsStadiaWithoutAKey() async throws {
        for key in [nil, "", "$(STADIA_API_KEY)", "paste-your-key-here"] as [String?] {
            let hosts = CallLog()
            let service = FallbackRoutingService.configured(
                stadiaAPIKey: key,
                backup: router("apple", .success(try route(duration: 3)), hosts),
                send: { request in
                    hosts.record(request.url?.host() ?? "")
                    throw URLError(.notConnectedToInternet)
                }
            )

            _ = try await service.route(from: origin, to: destination, options: RouteOptions())

            #expect(hosts.values == ["valhalla1.openstreetmap.de", "apple"], "key: \(key ?? "nil")")
        }
    }

    @Test
    func stadiaRequestCarriesTheConfiguredKey() {
        let endpoint = ValhallaEndpoint.stadia(apiKey: "key-123")

        #expect(endpoint.routeURL.absoluteString == "https://api.stadiamaps.com/route/v1?api_key=key-123")
        #expect(ValhallaEndpoint.publicDemo.routeURL.absoluteString == "https://valhalla1.openstreetmap.de/route")
    }
}
