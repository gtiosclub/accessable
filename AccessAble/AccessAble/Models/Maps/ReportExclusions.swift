import Foundation

/// The route options that avoid a set of active reports, within what Valhalla accepts. Pure, so a reroute when
/// reports change can choose the same way a route request does.
struct ReportExclusions: Equatable, Sendable {
    var options: RouteOptions
    /// The reports `options` excludes, in the order they were added.
    var excluded: [Report]

    /// Spoken when a route passes a report it couldn't avoid.
    static let warning = "A reported obstacle is on this route."
    /// Valhalla refuses a request with more than 50 exclusion points by default.
    static let maximumLocations = 40
    /// Metres of polygon perimeter. Valhalla refuses a request with more than 10 km by default.
    static let maximumPolygonPerimeter: Double = 5_000
    /// Metres from a route within which it passes a report.
    static let passingDistance: Double = 15

    /// `options` plus as many of `reports` as fit Valhalla's limits, nearest the straight line from `origin` to
    /// `destination` first: a route that bends still mostly keeps near it. A report with an area of at least three
    /// distinct points is excluded as a polygon, any other as its point. A polygon that would take the perimeter past
    /// `maximumPolygonPerimeter` is left out.
    static func make(
        from reports: [Report],
        origin: GeoCoordinate,
        destination: GeoCoordinate,
        adding options: RouteOptions = RouteOptions()
    ) -> ReportExclusions {
        let line = [origin, destination]
        let lineDistances = GeoMath.cumulativeDistances(along: line)
        let ordered = reports
            .map { report in
                let offset = points(of: report).map {
                    abs(GeoMath.project($0, onto: line, cumulativeDistances: lineDistances, segments: 0..<1).sideOffset)
                }.min() ?? .infinity
                return (report, offset)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)

        var exclusions = ReportExclusions(options: options, excluded: [])
        var perimeter = options.excludePolygons.reduce(0) { $0 + Self.perimeter(of: $1) }
        for report in ordered {
            if let ring = report.area.flatMap(Self.ring) {
                let length = Self.perimeter(of: ring)
                guard perimeter + length <= maximumPolygonPerimeter else { continue }
                perimeter += length
                exclusions.options.excludePolygons.append(ring)
            } else {
                guard exclusions.options.excludeLocations.count < maximumLocations else { continue }
                exclusions.options.excludeLocations.append(report.coordinate)
            }
            exclusions.excluded.append(report)
        }
        return exclusions
    }

    /// The reports whose point or any area corner is within `passingDistance` of `route`.
    static func reports(_ reports: [Report], passedBy route: NavigationRoute) -> [Report] {
        self.reports(reports, within: passingDistance, of: route)
    }

    /// The reports whose point or any area corner is within `distance` metres of `route`.
    static func reports(_ reports: [Report], within distance: Double, of route: NavigationRoute) -> [Report] {
        reports.filter { report in
            points(of: report).contains { abs(route.projection(of: $0).sideOffset) <= distance }
        }
    }

    /// Metres along `route` where it passes `report`, by the same points as `reports(_:passedBy:)`, searching only
    /// from `distance` along it on: nil if it passes the report only before then, or not at all.
    static func distanceAlong(_ route: NavigationRoute, passing report: Report, from distance: Double) -> Double? {
        let lastSegment = route.coordinates.count - 2
        let first = min(route.cumulativeDistances.lastIndex { $0 <= distance } ?? 0, lastSegment)
        return points(of: report)
            .map { route.projection(of: $0, segments: first..<lastSegment + 1) }
            .filter { abs($0.sideOffset) <= passingDistance && $0.distanceAlongRoute >= distance }
            .map(\.distanceAlongRoute)
            .min()
    }

    private static func points(of report: Report) -> [GeoCoordinate] {
        [report.coordinate] + (report.area ?? [])
    }

    /// The area without a closing point, or nil if it has fewer than three distinct points.
    private static func ring(_ area: [GeoCoordinate]) -> [GeoCoordinate]? {
        var ring = area
        if ring.count > 1, ring.first == ring.last { ring.removeLast() }
        return Set(ring).count >= 3 ? ring : nil
    }

    /// Metres around the polygon, closing edge included.
    private static func perimeter(of ring: [GeoCoordinate]) -> Double {
        guard let first = ring.first else { return 0 }
        return zip(ring, ring.dropFirst() + [first]).reduce(0) { $0 + GeoMath.distance(from: $1.0, to: $1.1) }
    }
}
