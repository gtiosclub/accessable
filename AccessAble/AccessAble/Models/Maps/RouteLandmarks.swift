import Foundation

/// A building the user walks past, or arrives at, on a route: what a sign the camera reads could confirm (LAND-2).
struct RouteLandmark: Equatable, Sendable {
    var name: String
    var aliases: [String]
    var isDestination: Bool
    /// The building's outline point closest to the route.
    var coordinate: GeoCoordinate
    /// Metres from the route start to where the building is closest.
    var distanceAlongRoute: Double
    /// Metres from the route to the building: negative left of the direction of travel, positive right.
    var sideOffset: Double
    /// Only filled in for the destination, for finding the way in on arrival.
    var entrances: [CampusEntrance]

    var allNames: [String] { [name] + aliases }
}

enum RouteLandmarks {
    /// The buildings within `visibleWithin` metres of the route, nearest along the route first, plus the destination's
    /// building wherever it is.
    ///
    /// - Closeness is measured to outline vertices, not edges, so a long blank wall can measure a little farther than
    ///   it is. Campus outlines have a vertex every few metres at corners, which is where signs and doors are.
    /// - The destination's building is the one whose outline contains the destination, else the one with a vertex
    ///   within `destinationMatchRadius` of it. The destination's own name is added to its names, since search
    ///   results don't always use OpenStreetMap's.
    static func along(
        _ route: NavigationRoute,
        destination: Destination?,
        buildings: [CampusBuilding] = CampusLandmarks.buildings,
        visibleWithin: Double = 40,
        destinationMatchRadius: Double = 30
    ) -> [RouteLandmark] {
        let destinationBuilding = destination.flatMap { building(at: $0.coordinate, in: buildings, within: destinationMatchRadius) }
        let area = Area(around: route.coordinates, margin: max(visibleWithin, destinationMatchRadius))

        var landmarks: [RouteLandmark] = []
        for (index, building) in buildings.enumerated() {
            let isDestination = index == destinationBuilding
            let vertices = building.outlines.joined()
            guard isDestination || vertices.contains(where: area.contains) else { continue }

            let closest = vertices
                .map { route.projection(of: $0) }
                .filter { $0.sideOffset.isFinite }
                .min { abs($0.sideOffset) < abs($1.sideOffset) }
            guard let closest, isDestination || abs(closest.sideOffset) <= visibleWithin else { continue }

            var aliases = building.aliases
            if isDestination, let name = destination?.name, name != building.name, !aliases.contains(name) {
                aliases.append(name)
            }
            landmarks.append(RouteLandmark(
                name: building.name,
                aliases: aliases,
                isDestination: isDestination,
                coordinate: closest.originalCoordinate,
                distanceAlongRoute: closest.distanceAlongRoute,
                sideOffset: closest.sideOffset,
                entrances: isDestination ? building.entrances : []
            ))
        }
        return landmarks.sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
    }

    /// Index of the building containing `point`, else of the one with the nearest vertex within `radius` metres.
    static func building(at point: GeoCoordinate, in buildings: [CampusBuilding], within radius: Double) -> Int? {
        if let inside = buildings.firstIndex(where: { $0.contains(point) }) { return inside }
        let nearest = buildings.indices
            .map { index in
                (index, buildings[index].outlines.joined().map { GeoMath.distance(from: point, to: $0) }.min() ?? .infinity)
            }
            .min { $0.1 < $1.1 }
        guard let nearest, nearest.1 <= radius else { return nil }
        return nearest.0
    }

    /// A latitude and longitude box around the route, so far buildings are skipped before any projection.
    private struct Area {
        let south: Double, north: Double, west: Double, east: Double

        init(around coordinates: [GeoCoordinate], margin: Double) {
            // a degree of latitude is about 111 km; a degree of longitude shrinks with latitude
            let latitudes = coordinates.map(\.latitude)
            let longitudes = coordinates.map(\.longitude)
            let latitudeMargin = margin / 111_000
            let middle = ((latitudes.min() ?? 0) + (latitudes.max() ?? 0)) / 2
            let longitudeMargin = margin / (111_000 * max(cos(middle * .pi / 180), 0.01))
            south = (latitudes.min() ?? 0) - latitudeMargin
            north = (latitudes.max() ?? 0) + latitudeMargin
            west = (longitudes.min() ?? 0) - longitudeMargin
            east = (longitudes.max() ?? 0) + longitudeMargin
        }

        func contains(_ point: GeoCoordinate) -> Bool {
            (south...north).contains(point.latitude) && (west...east).contains(point.longitude)
        }
    }
}
