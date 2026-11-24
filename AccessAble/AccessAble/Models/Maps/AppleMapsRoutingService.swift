import Foundation
import MapKit
import os

private let log = Logger(subsystem: "AccessAble", category: "Routing")

/// Asks Apple Maps for walking routes. The backup when neither Valhalla server answers: it needs no key and has no
/// fair-use limit, but its steps are plainer than Valhalla's and know nothing of campus crossings.
struct AppleMapsRoutingService: RoutingService {
    func route(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async throws -> NavigationRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.clCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.clCoordinate))
        request.transportType = .walking

        let response: MKDirections.Response
        do {
            response = try await MKDirections(request: request).calculate()
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            log.error("Apple Maps request failed: \(error.localizedDescription, privacy: .public)")
            if (error as? MKError)?.code == .directionsNotFound { throw RoutingError.noRouteFound }
            throw RoutingError.serverUnavailable
        }
        guard let route = response.routes.first else { throw RoutingError.noRouteFound }
        return try Self.navigationRoute(from: route)
    }

    private static func navigationRoute(from route: MKRoute) throws -> NavigationRoute {
        var coordinates: [GeoCoordinate] = []
        var steps: [RouteStep] = []
        for step in route.steps {
            let points = step.polyline.coordinates
            guard !points.isEmpty else { continue }
            // each step's line starts where the previous one ended
            let start = coordinates.isEmpty ? coordinates.count : coordinates.count - 1
            coordinates += coordinates.isEmpty ? points : Array(points.dropFirst())
            // Apple Maps' first step has no text and the last arrives; both are replaced below
            if steps.isEmpty {
                steps.append(RouteStep(kind: .depart, coordinateIndex: 0,
                                       instruction: step.instructions.isEmpty ? "Follow the path." : step.instructions,
                                       spokenInstruction: step.instructions.isEmpty ? "Follow the path." : step.instructions))
            } else if !step.instructions.isEmpty {
                steps.append(RouteStep(kind: kind(of: step.instructions), coordinateIndex: start,
                                       instruction: step.instructions, spokenInstruction: step.instructions))
            }
        }
        guard coordinates.count >= 2 else { throw RoutingError.invalidResponse }
        steps.append(RouteStep(kind: .arrive, coordinateIndex: coordinates.count - 1,
                               instruction: "Arrive at your destination.",
                               spokenInstruction: "You have arrived at your destination."))
        do {
            return try NavigationRoute(coordinates: coordinates, steps: steps, estimatedDuration: route.expectedTravelTime)
        } catch {
            log.error("Could not validate Apple Maps route: \(String(describing: error), privacy: .public)")
            throw RoutingError.invalidResponse
        }
    }

    private static func kind(of instructions: String) -> ManeuverKind {
        let text = instructions.lowercased()
        if text.contains("u-turn") { return .uTurn }
        if text.contains("stairs") { return .stairs }
        let isLeft = text.contains("left"), isRight = text.contains("right")
        guard isLeft != isRight else { return .straight }
        let isSlight = text.contains("slight") || text.contains("bear")
        return isLeft ? (isSlight ? .slightLeft : .turnLeft) : (isSlight ? .slightRight : .turnRight)
    }
}

private extension MKPolyline {
    var coordinates: [GeoCoordinate] {
        var buffer = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        getCoordinates(&buffer, range: NSRange(location: 0, length: pointCount))
        return buffer.map(GeoCoordinate.init)
    }
}
