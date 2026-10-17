import Foundation
import os

private let log = Logger(subsystem: "AccessAble", category: "Routing")

/// Asks a Valhalla server for walking routes.
struct ValhallaRoutingService: RoutingService {
    private let endpoint: ValhallaEndpoint
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// `send` performs the HTTP request; tests replace it so they never reach the network.
    init(
        endpoint: ValhallaEndpoint = .publicDemo,
        send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(for: $0)
        }
    ) {
        self.endpoint = endpoint
        self.send = send
    }

    func route(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async throws -> NavigationRoute {
        guard options.walkingSpeed.isFinite, options.walkingSpeed > 0 else {
            log.error("Invalid walking speed: \(options.walkingSpeed, privacy: .public) m/s")
            throw RoutingError.invalidResponse
        }
        let request: URLRequest
        do {
            request = try makeRequest(from: origin, to: destination, options: options)
        } catch {
            log.error("Could not encode Valhalla request: \(error.localizedDescription, privacy: .public)")
            throw RoutingError.invalidResponse
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            log.error("Valhalla request failed: \(error.localizedDescription, privacy: .public)")
            throw RoutingError.serverUnavailable
        }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            log.error("Valhalla response was not HTTP")
            throw RoutingError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            return try decodeRoute(data)
        case 400:
            throw requestError(data)
        // 403 is the shared demo server blocking or throttling us, not a bug in our request.
        case 403, 429, 500...599:
            log.error("Valhalla unavailable: HTTP \(http.statusCode, privacy: .public)")
            throw RoutingError.serverUnavailable
        default:
            log.error("Unexpected Valhalla response: HTTP \(http.statusCode, privacy: .public)")
            throw RoutingError.invalidResponse
        }
    }

    private func decodeRoute(_ data: Data) throws -> NavigationRoute {
        do {
            return try ValhallaGeometryDecoder.decodeRoute(from: data)
        } catch ValhallaGeometryDecoder.DecodeError.unsuccessfulRoute {
            log.error("Valhalla trip status was unsuccessful")
            throw RoutingError.noRouteFound
        } catch {
            log.error("Could not decode Valhalla route: \(String(describing: error), privacy: .public)")
            throw RoutingError.invalidResponse
        }
    }

    /// Valhalla error codes meaning it can't route between these points.
    private static let noRouteErrorCodes: Set<Int> = [
        154, // path distance exceeds the max distance limit
        170, // locations are in unconnected regions
        171, // no suitable edges near location
        172, // exceeded breakage distance for all pairs
        442, // no path could be found for input
    ]

    /// Any other rejection means our request was wrong, which is a bug rather than a missing route.
    private func requestError(_ data: Data) -> RoutingError {
        let body: ErrorResponse
        do {
            body = try JSONDecoder().decode(ErrorResponse.self, from: data)
        } catch {
            log.error("Could not decode Valhalla error: \(String(describing: error), privacy: .public)")
            return .invalidResponse
        }
        // Valhalla's message can echo request details, so only the code is logged.
        log.error("Valhalla rejected the request: error_code \(body.errorCode, privacy: .public)")
        return Self.noRouteErrorCodes.contains(body.errorCode) ? .noRouteFound : .invalidResponse
    }

    private func makeRequest(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) throws -> URLRequest {
        // Valhalla documents 0.5–25 km/h for walking_speed.
        let walkingSpeed = min(max(options.walkingSpeed * 3.6, 0.5), 25)
        let body = RouteRequest(
            locations: [Location(origin), Location(destination)],
            costingOptions: CostingOptions(pedestrian: Pedestrian(walkingSpeed: walkingSpeed))
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        var request = URLRequest(url: endpoint.baseURL.appending(path: "route"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(endpoint.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try encoder.encode(body)
        return request
    }

    private struct ErrorResponse: Decodable {
        let errorCode: Int

        private enum CodingKeys: String, CodingKey {
            case errorCode = "error_code"
        }
    }

    private struct RouteRequest: Encodable {
        let locations: [Location]
        let costing = "pedestrian"
        let costingOptions: CostingOptions
        // The decoder converts either unit; kilometres keeps the response metric.
        let units = "kilometers"
        let language = "en-US"
        let directionsType = "instructions"
    }

    private struct Location: Encodable {
        let lat: Double
        let lon: Double

        init(_ coordinate: GeoCoordinate) {
            lat = coordinate.latitude
            lon = coordinate.longitude
        }
    }

    private struct CostingOptions: Encodable {
        let pedestrian: Pedestrian
    }

    private struct Pedestrian: Encodable {
        /// Kilometres per hour.
        let walkingSpeed: Double
    }
}
