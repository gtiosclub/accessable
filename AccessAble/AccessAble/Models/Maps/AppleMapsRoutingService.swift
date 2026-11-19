import MapKit
import os

private let log = Logger(subsystem: "AccessAble", category: "Routing")

/// Asks Apple Maps for a walking route. Apple's routes know nothing about stairs, kerbs or step-free paths, so this
/// is only a backup for when Valhalla can't answer; see `FallbackRoutingService`.
struct AppleMapsRoutingService: RoutingService {
    func route(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async throws -> NavigationRoute {
        guard options.walkingSpeed.isFinite, options.walkingSpeed > 0 else {
            log.error("Invalid walking speed: \(options.walkingSpeed, privacy: .public) m/s")
            throw RoutingError.invalidResponse
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude),
                                   address: nil)
        request.destination = MKMapItem(
            location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil
        )
        request.transportType = .walking
        request.requestsAlternateRoutes = false

        let response: MKDirections.Response
        do {
            response = try await MKDirections(request: request).calculate()
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            log.error("Apple Maps directions failed: \(error.localizedDescription, privacy: .public)")
            throw (error as? MKError)?.code == .directionsNotFound
                ? RoutingError.noRouteFound : RoutingError.serverUnavailable
        }
        try Task.checkCancellation()

        guard let route = response.routes.first else { throw RoutingError.noRouteFound }
        do {
            // the user's own pace, as Valhalla uses, rather than Apple's average walker
            return try NavigationRoute(appleMapsRoute: route, duration: route.distance / options.walkingSpeed)
        } catch {
            log.error("Could not convert Apple Maps route: \(String(describing: error), privacy: .public)")
            throw RoutingError.invalidResponse
        }
    }
}
