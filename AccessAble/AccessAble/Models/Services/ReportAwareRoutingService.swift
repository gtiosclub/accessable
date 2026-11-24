import Foundation

/// Adds active community report exclusions to every route request.
struct ReportAwareRoutingService: RoutingService {
    private let base: any RoutingService
    private let reports: any ReportService

    init(base: any RoutingService, reports: any ReportService) {
        self.base = base
        self.reports = reports
    }

    func route(
        from origin: GeoCoordinate,
        to destination: GeoCoordinate,
        options: RouteOptions
    ) async throws -> NavigationRoute {
        let center = GeoCoordinate(
            latitude: (origin.latitude + destination.latitude) / 2,
            longitude: (origin.longitude + destination.longitude) / 2
        )
        let radius = GeoMath.distance(from: origin, to: destination) / 2 + 500

        // Do not silently route through unknown reports if report fetching fails.
        let nearby = try await reports.reports(near: center, radius: radius)

        let routeDistances = [
            0,
            GeoMath.distance(from: origin, to: destination)
        ]

        let active = nearby.filter { report in
            guard report.expiresAt > .now else { return false }
            let points = report.area?.isEmpty == false
                ? report.area!
                : [report.coordinate]

            return points.contains { point in
                let projection = GeoMath.project(
                    point,
                    onto: [origin, destination],
                    cumulativeDistances: routeDistances,
                    segments: 0..<1
                )
                return projection.distanceAlongRoute.isFinite
                    && projection.distanceAlongRoute >= 0
                    && projection.distanceAlongRoute <= routeDistances[1]
                    && abs(projection.sideOffset) <= 100
            }
        }

        guard !active.isEmpty else {
            return try await base.route(
                from: origin,
                to: destination,
                options: options
            )
        }

        let pointExclusions = active
            .filter { ($0.area?.count ?? 0) < 3 }
            .map(\.coordinate)

        let polygonExclusions = active.compactMap { report -> [GeoCoordinate]? in
            guard let area = report.area, area.count >= 3 else { return nil }
            return area
        }

        let restrictedOptions = RouteOptions(
            walkingSpeed: options.walkingSpeed,
            excludeLocations: options.excludeLocations + pointExclusions,
            excludePolygons: options.excludePolygons + polygonExclusions
        )

        do {
            let route = try await base.route(
                from: origin,
                to: destination,
                options: restrictedOptions
            )
            return try NavigationRoute(
                coordinates: route.coordinates,
                steps: route.steps,
                estimatedDuration: route.estimatedDuration,
                avoidedReports: active
            )
        } catch RoutingError.noRouteFound {
            let fallback = try await base.route(
                from: origin,
                to: destination,
                options: options
            )
            return try NavigationRoute(
                coordinates: fallback.coordinates,
                steps: fallback.steps,
                estimatedDuration: fallback.estimatedDuration,
                unavoidedReports: active
            )
        }
    }
}
