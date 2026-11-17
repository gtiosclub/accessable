import Foundation

/// A street crossing the route uses, for the "Crosswalk ahead" callout (NAV-6).
struct RouteCrossing: Equatable, Sendable {
    /// Metres from the route start to the crossing.
    var distanceAlongRoute: Double
    var control: CampusCrossing.Control
    var audibleSignal: Bool
}

enum RouteCrossings {
    // both the route and the crossings are OpenStreetMap geometry, so a crossing the route uses lies on it to within a
    // metre or two, while one over the road the user walks beside sits 5-10 m away and must not be announced
    private static let onRouteDistance: Double = 5
    // a crossing node and the centre of its crossing way often describe the same crossing a few metres apart
    private static let mergeDistance: Double = 10

    /// The crossings on the route, nearest the start first, with entries describing the same crossing merged.
    ///
    /// A crossing past either end of the route projects onto that end, and its offset is then its distance from it,
    /// so one beyond the destination is kept only within `onRouteDistance` of it.
    static func along(_ route: NavigationRoute,
                      crossings: [CampusCrossing] = CampusCrossings.all) -> [RouteCrossing] {
        let area = RouteLandmarks.Area(around: route.coordinates, margin: onRouteDistance)
        let onRoute = crossings
            .filter { area.contains($0.coordinate) }
            .compactMap { crossing -> RouteCrossing? in
                let projection = route.projection(of: crossing.coordinate)
                guard projection.sideOffset.isFinite, abs(projection.sideOffset) <= onRouteDistance else { return nil }
                return RouteCrossing(distanceAlongRoute: projection.distanceAlongRoute, control: crossing.control,
                                     audibleSignal: crossing.audibleSignal)
            }
            .sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }

        var merged: [RouteCrossing] = []
        for crossing in onRoute {
            guard var last = merged.last,
                  crossing.distanceAlongRoute - last.distanceAlongRoute <= mergeDistance else {
                merged.append(crossing)
                continue
            }
            last.audibleSignal = last.audibleSignal || crossing.audibleSignal
            if rank(crossing.control) > rank(last.control) { last.control = crossing.control }
            merged[merged.count - 1] = last
        }
        return merged
    }

    /// How much a control tells the user: a signal most, and "unmarked" only when nothing says otherwise.
    private static func rank(_ control: CampusCrossing.Control) -> Int {
        switch control {
        case .signals: 3
        case .marked: 2
        case .unknown: 1
        case .unmarked: 0
        }
    }
}
