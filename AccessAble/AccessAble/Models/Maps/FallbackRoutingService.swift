import Foundation
import os

private let log = Logger(subsystem: "AccessAble", category: "Routing")

/// Asks each routing service in order and returns the first route found, so a server that is down, out of credits
/// or throttling only costs the next one a request.
struct FallbackRoutingService: RoutingService {
    private let services: [any RoutingService]

    /// - Parameter services: Tried first to last; at least one.
    init(_ services: [any RoutingService]) {
        precondition(!services.isEmpty, "FallbackRoutingService needs at least one service")
        self.services = services
    }

    /// Stadia (when `stadiaAPIKey` is set), then the FOSSGIS demo server, then `backup`. Changing the server is a
    /// `STADIA_API_KEY` change in `Secrets.xcconfig`, not a code change. `send` performs the HTTP requests of both
    /// Valhalla servers; tests replace it so they never reach the network.
    static func configured(
        stadiaAPIKey: String? = ValhallaEndpoint.configuredStadiaKey,
        backup: any RoutingService = AppleMapsRoutingService(),
        send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(for: $0)
        }
    ) -> FallbackRoutingService {
        var services: [any RoutingService] = []
        if let key = ValhallaEndpoint.stadiaKey(from: stadiaAPIKey) {
            services.append(ValhallaRoutingService(endpoint: .stadia(apiKey: key), send: send))
        }
        services.append(ValhallaRoutingService(endpoint: .publicDemo, send: send))
        services.append(backup)
        return FallbackRoutingService(services)
    }

    func route(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async throws -> NavigationRoute {
        var lastError: any Error = RoutingError.serverUnavailable
        for (index, service) in services.enumerated() {
            do {
                return try await service.route(from: origin, to: destination, options: options)
            } catch {
                // a cancelled request is the caller giving up, not a server to skip
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                log.error("Routing server \(index, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                lastError = error
            }
        }
        throw lastError
    }
}
