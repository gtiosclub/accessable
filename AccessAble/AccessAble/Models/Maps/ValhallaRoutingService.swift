import Foundation

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
        let request = try makeRequest(from: origin, to: destination, options: options)
        let (data, _) = try await send(request)
        return try ValhallaGeometryDecoder.decodeRoute(from: data)
    }

    private func makeRequest(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) throws -> URLRequest {
        precondition(options.walkingSpeed > 0, "RouteOptions.walkingSpeed must be greater than 0")
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
