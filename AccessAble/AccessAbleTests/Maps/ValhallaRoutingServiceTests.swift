import Foundation
import Testing
@testable import AccessAble

struct ValhallaRoutingServiceTests {
    private static let endpoint = ValhallaEndpoint(
        baseURL: URL(string: "https://valhalla.example")!, userAgent: "AccessAble tests"
    )
    // The saved response's request locations.
    private static let origin = GeoCoordinate(latitude: 33.775, longitude: -84.399)
    private static let destination = GeoCoordinate(latitude: 33.7756, longitude: -84.4038)

    private func fixture() throws -> Data {
        let url = try #require(Bundle.main.url(forResource: "valhalla-route-sample", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func modifiedTrip(_ edit: (inout [String: Any]) throws -> Void) throws -> Data {
        var response = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        var trip = try #require(response["trip"] as? [String: Any])
        try edit(&trip)
        response["trip"] = trip
        return try JSONSerialization.data(withJSONObject: response)
    }

    private static func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: endpoint.routeURL, statusCode: status,
                        httpVersion: nil, headerFields: nil)!
    }

    private func service(status: Int, body: Data) -> ValhallaRoutingService {
        ValhallaRoutingService(endpoint: Self.endpoint) { _ in (body, Self.httpResponse(status)) }
    }

    private func route(with service: ValhallaRoutingService, options: RouteOptions = RouteOptions())
        async throws -> NavigationRoute {
        try await service.route(from: Self.origin, to: Self.destination, options: options)
    }

    // MARK: - Decoding the saved response

    @Test
    func convertsSavedResponseIntoRoute() throws {
        let route = try ValhallaGeometryDecoder.decodeRoute(from: fixture())
        #expect(route.coordinates.count == 35)
        #expect(route.steps.count == 9)
        #expect(route.steps.map(\.coordinateIndex) == [0, 3, 5, 6, 11, 26, 32, 33, 34])
        #expect(route.steps.first?.kind == .depart)
        #expect(route.steps.last?.kind == .arrive)
        #expect(route.steps.last?.coordinateIndex == 34)
        #expect(route.estimatedDuration == 417.444)
        // GeoMath's sphere and Valhalla's own edge lengths differ slightly.
        #expect(abs(route.totalDistance - 573) / 573 < 0.02)
    }

    @Test
    func rejectsMoreThanOneLeg() throws {
        let data = try modifiedTrip { trip in
            let legs = try #require(trip["legs"] as? [[String: Any]])
            trip["legs"] = legs + legs
        }
        #expect(throws: ValhallaGeometryDecoder.DecodeError.unexpectedLegCount) {
            try ValhallaGeometryDecoder.decodeRoute(from: data)
        }
    }

    // MARK: - Request

    private actor RequestRecorder {
        private(set) var requests: [URLRequest] = []
        func record(_ request: URLRequest) { requests.append(request) }
    }

    private func sentRequest(
        endpoint: ValhallaEndpoint = ValhallaRoutingServiceTests.endpoint, options: RouteOptions = RouteOptions()
    ) async throws -> URLRequest {
        let recorder = RequestRecorder()
        let body = try fixture()
        let service = ValhallaRoutingService(endpoint: endpoint) { request in
            await recorder.record(request)
            return (body, Self.httpResponse(200))
        }
        _ = try await route(with: service, options: options)
        let requests = await recorder.requests
        #expect(requests.count == 1)
        return try #require(requests.first)
    }

    private func jsonBody(of request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func pedestrian(in request: URLRequest) throws -> [String: Any] {
        let costingOptions = try #require(jsonBody(of: request)["costing_options"] as? [String: Any])
        return try #require(costingOptions["pedestrian"] as? [String: Any])
    }

    private func walkingSpeed(in request: URLRequest) throws -> Double {
        try #require(pedestrian(in: request)["walking_speed"] as? Double)
    }

    @Test
    func encodesPointAndAreaExclusionsForValhalla() async throws {
        let polygon = [
            GeoCoordinate(latitude: 33.775, longitude: -84.396),
            GeoCoordinate(latitude: 33.776, longitude: -84.396),
            GeoCoordinate(latitude: 33.776, longitude: -84.397)
        ]

        let request = try await sentRequest(options: RouteOptions(
            excludeLocations: [
                GeoCoordinate(latitude: 33.7755, longitude: -84.398)
            ],
            excludePolygons: [polygon]
        ))

        let body = try jsonBody(of: request)
        let locations = try #require(body["exclude_locations"] as? [[String: Double]])
        #expect(locations == [["lat": 33.7755, "lon": -84.398]])

        let polygons = try #require(body["exclude_polygons"] as? [[[Double]]])
        #expect(polygons.count == 1)
        #expect(polygons[0].count == 4)
        #expect(polygons[0].first == polygons[0].last)
        #expect(polygons[0][0] == [-84.396, 33.775])
    }

    @Test
    func postsPedestrianRouteRequest() async throws {
        let request = try await sentRequest()
        #expect(request.httpMethod == "POST")
        #expect(request.url == URL(string: "https://valhalla.example/route"))
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "AccessAble tests")
        #expect(request.timeoutInterval == 15)

        let body = try jsonBody(of: request)
        let locations = try #require(body["locations"] as? [[String: Double]])
        #expect(locations == [["lat": 33.775, "lon": -84.399], ["lat": 33.7756, "lon": -84.4038]])
        #expect(body["costing"] as? String == "pedestrian")
        #expect(body["units"] as? String == "kilometers")
        #expect(body["language"] as? String == "en-US")
        #expect(body["directions_type"] as? String == "instructions")
        #expect(abs(try walkingSpeed(in: request) - 4.32) < 1e-9)
    }

    @Test(arguments: ["https://h/valhalla", "https://h/valhalla/"])
    func appendsRoutePathToBaseURL(_ baseURL: String) async throws {
        let endpoint = ValhallaEndpoint(baseURL: try #require(URL(string: baseURL)))
        let request = try await sentRequest(endpoint: endpoint)
        #expect(request.url?.absoluteString == "https://h/valhalla/route")
    }

    @Test
    func noAuthorizationWithoutStadiaKey() async throws {
        let request = try await sentRequest()
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func stadiaPostsToRouteV1WithKeyInHeader() async throws {
        let request = try await sentRequest(endpoint: .stadia(apiKey: "test-key"))
        #expect(request.url == URL(string: "https://api.stadiamaps.com/route/v1"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Stadia-Auth test-key")
        #expect(request.url?.query == nil)
    }

    @Test(arguments: [
        nil, "", "  ", "\n", "$(STADIA_API_KEY)", "paste-your-key-here", "PASTE-YOUR-KEY-HERE", "YOUR_KEY", "<key>",
        "\"paste-your-key-here\"", "\"\"", "''", 42,
    ] as [(any Sendable)?])
    func missingStadiaKeyIsNil(_ value: (any Sendable)?) {
        #expect(StadiaConfig.apiKey(from: value) == nil)
    }

    @Test
    func stadiaKeyIsTrimmed() {
        #expect(StadiaConfig.apiKey(from: " abc ") == "abc")
        #expect(StadiaConfig.apiKey(from: "\nabc\n") == "abc")
    }

    @Test(arguments: ["\"abc\"", "'abc'", " \"abc\" "])
    func stadiaKeyQuotesAreStripped(_ value: String) {
        #expect(StadiaConfig.apiKey(from: value) == "abc")
    }

    @Test(arguments: [401, 403])
    func rejectedStadiaKeyIsNotAuthorized(_ status: Int) async {
        let service = ValhallaRoutingService(endpoint: .stadia(apiKey: "k")) { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: RoutingError.notAuthorized) {
            try await route(with: service)
        }
    }

    @Test(arguments: [(0.01, 0.5), (100.0, 25.0)])
    func clampsWalkingSpeedToValhallaRange(metresPerSecond: Double, expectedKilometresPerHour: Double) async throws {
        let request = try await sentRequest(options: RouteOptions(walkingSpeed: metresPerSecond))
        #expect(try walkingSpeed(in: request) == expectedKilometresPerHour)
    }

    @Test
    func defaultOptionsSendOnlyWalkingSpeed() async throws {
        let request = try await sentRequest()
        #expect(Set(try pedestrian(in: request).keys) == ["walking_speed"])
    }

    @Test
    func encodesEachPedestrianPreference() async throws {
        let request = try await sentRequest(options: RouteOptions(
            stepPenalty: 3600, elevatorPenalty: 120, useHills: 0.2, useLit: 0.8,
            walkwayFactor: 0.9, sidewalkFactor: 0.8, alleyFactor: 2, drivewayFactor: 5,
            servicePenalty: 60, serviceFactor: 3, useTracks: 0.1, maxHikingDifficulty: 1
        ))

        let pedestrian = try pedestrian(in: request)
        let expected: [String: Double] = [
            "step_penalty": 3600, "elevator_penalty": 120, "use_hills": 0.2, "use_lit": 0.8,
            "walkway_factor": 0.9, "sidewalk_factor": 0.8, "alley_factor": 2, "driveway_factor": 5,
            "service_penalty": 60, "service_factor": 3, "use_tracks": 0.1, "max_hiking_difficulty": 1,
        ]
        #expect(Set(pedestrian.keys) == Set(expected.keys).union(["walking_speed"]))
        for (key, value) in expected {
            #expect(pedestrian[key] as? Double == value, "\(key)")
        }
    }

    @Test
    func leavesOutUnsetPreferences() async throws {
        let request = try await sentRequest(options: RouteOptions(stepPenalty: 3600))
        #expect(Set(try pedestrian(in: request).keys) == ["walking_speed", "step_penalty"])
        let data = try #require(request.httpBody)
        let body = try #require(String(data: data, encoding: .utf8))
        #expect(!body.contains("null"))
    }

    @Test
    func clampsPreferencesToValhallaRanges() async throws {
        let low = try pedestrian(in: try await sentRequest(options: RouteOptions(
            stepPenalty: -1, elevatorPenalty: -1, useHills: -1, useLit: -1,
            walkwayFactor: 0, sidewalkFactor: 0, alleyFactor: 0, drivewayFactor: 0,
            servicePenalty: -1, serviceFactor: 0, useTracks: -1, maxHikingDifficulty: -1
        )))
        let high = try pedestrian(in: try await sentRequest(options: RouteOptions(
            stepPenalty: 1e9, elevatorPenalty: 1e9, useHills: 2, useLit: 2,
            walkwayFactor: 1e9, sidewalkFactor: 1e9, alleyFactor: 1e9, drivewayFactor: 1e9,
            servicePenalty: 1e9, serviceFactor: 1e9, useTracks: 2, maxHikingDifficulty: 7
        )))

        for key in ["step_penalty", "elevator_penalty", "service_penalty"] {
            #expect(low[key] as? Double == 0, "\(key)")
            #expect(high[key] as? Double == 43_200, "\(key)")
        }
        for key in ["use_hills", "use_lit", "use_tracks"] {
            #expect(low[key] as? Double == 0, "\(key)")
            #expect(high[key] as? Double == 1, "\(key)")
        }
        for key in ["walkway_factor", "sidewalk_factor", "alley_factor", "driveway_factor", "service_factor"] {
            #expect(low[key] as? Double == 0.1, "\(key)")
            #expect(high[key] as? Double == 100_000, "\(key)")
        }
        #expect(low["max_hiking_difficulty"] as? Int == 0)
        #expect(high["max_hiking_difficulty"] as? Int == 6)
    }

    @Test(arguments: [Double.nan, 0])
    func rejectsInvalidWalkingSpeedWithoutSending(_ metresPerSecond: Double) async {
        let recorder = RequestRecorder()
        let service = ValhallaRoutingService(endpoint: Self.endpoint) { request in
            await recorder.record(request)
            return (Data(), Self.httpResponse(200))
        }
        await #expect(throws: RoutingError.invalidResponse) {
            try await route(with: service, options: RouteOptions(walkingSpeed: metresPerSecond))
        }
        #expect(await recorder.requests.isEmpty)
    }

    // MARK: - Responses and errors

    @Test
    func returnsRouteFromSavedResponse() async throws {
        let route = try await route(with: service(status: 200, body: fixture()))
        #expect(route == (try ValhallaGeometryDecoder.decodeRoute(from: fixture())))
    }

    @Test
    func transportFailureIsServerUnavailable() async {
        let service = ValhallaRoutingService(endpoint: Self.endpoint) { _ in
            throw URLError(.notConnectedToInternet)
        }
        await #expect(throws: RoutingError.serverUnavailable) {
            try await route(with: service)
        }
    }

    @Test
    func cancelledRequestIsCancellationError() async {
        let service = ValhallaRoutingService(endpoint: Self.endpoint) { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) {
            try await route(with: service)
        }
    }

    private struct UnrelatedError: Error {}

    /// Cancels the routing task while `send` is suspended, then lets `send` finish with `outcome`.
    private func routeCancelledDuringSend(
        outcome: @escaping @Sendable () throws -> (Data, URLResponse)
    ) async throws -> NavigationRoute {
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (resume, resumeContinuation) = AsyncStream<Void>.makeStream()
        let service = ValhallaRoutingService(endpoint: Self.endpoint) { _ in
            startedContinuation.yield()
            // Returns once resumed or cancelled; either way the task is already cancelled by then.
            for await _ in resume { break }
            return try outcome()
        }
        let task = Task { try await route(with: service) }
        for await _ in started { break }
        task.cancel()
        resumeContinuation.yield()
        return try await task.value
    }

    @Test
    func cancellationWinsOverUnrelatedSendError() async {
        await #expect(throws: CancellationError.self) {
            try await routeCancelledDuringSend { throw UnrelatedError() }
        }
    }

    @Test
    func cancellationWinsOverSuccessfulResponse() async throws {
        let body = try fixture()
        await #expect(throws: CancellationError.self) {
            try await routeCancelledDuringSend { (body, Self.httpResponse(200)) }
        }
    }

    @Test
    func nonHTTPResponseIsInvalid() async throws {
        let body = try fixture()
        let service = ValhallaRoutingService(endpoint: Self.endpoint) { request in
            (body, URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }
        await #expect(throws: RoutingError.invalidResponse) {
            try await route(with: service)
        }
    }

    private static func valhallaError(_ code: Int) -> String {
        #"{"error_code":\#(code),"error":"Valhalla message","status_code":400,"status":"Bad Request"}"#
    }

    @Test(arguments: [
        (403, "", RoutingError.serverUnavailable),
        (401, "", .serverUnavailable),
        (402, "", .usageLimitReached),
        (408, "", .serverUnavailable),
        (429, "", .usageLimitReached),
        (500, "", .serverUnavailable),
        (503, "", .serverUnavailable),
        (400, valhallaError(154), .noRouteFound),
        (400, valhallaError(170), .noRouteFound),
        (400, valhallaError(171), .noRouteFound),
        (400, valhallaError(172), .noRouteFound),
        (400, valhallaError(442), .noRouteFound),
        (400, valhallaError(157), .exclusionsRejected),
        (400, valhallaError(167), .exclusionsRejected),
        (400, valhallaError(100), .invalidResponse),
        (400, "Bad Request", .invalidResponse),
        (404, "", .invalidResponse),
        (200, "garbage", .invalidResponse),
    ])
    func mapsErrorResponses(status: Int, body: String, expected: RoutingError) async {
        await #expect(throws: expected) {
            try await route(with: service(status: status, body: Data(body.utf8)))
        }
    }

    @Test
    func unsuccessfulTripIsNoRoute() async throws {
        let data = try modifiedTrip { $0["status"] = 442 }
        await #expect(throws: RoutingError.noRouteFound) {
            try await route(with: service(status: 200, body: data))
        }
    }

    @Test
    func routeFailingValidationIsInvalid() async throws {
        // Turning the arrival into a straight leaves the route without an arrival step.
        let data = try modifiedTrip { trip in
            var legs = try #require(trip["legs"] as? [[String: Any]])
            var maneuvers = try #require(legs[0]["maneuvers"] as? [[String: Any]])
            maneuvers[maneuvers.count - 1]["type"] = 8
            legs[0]["maneuvers"] = maneuvers
            trip["legs"] = legs
        }
        await #expect(throws: RoutingError.invalidResponse) {
            try await route(with: service(status: 200, body: data))
        }
    }
}
