import Foundation

/// Where a point-to-scan result came from; campus and saved places outrank MapKit.
enum PointToScanPlaceSource: String, Sendable {
    case campus
    case saved
    case mapKit
}

/// One named place the scanner can announce.
struct PointToScanPlace: Equatable, Sendable {
    let id: String
    let name: String
    let coordinate: GeoCoordinate
    let source: PointToScanPlaceSource
}

/// Chooses which place lies in the direction the top of the phone points.
enum PointToScanSelection {
    static let maxDistance: Double = 400
    static let bearingWindow: Double = 15
    /// MapKit hits this close to a campus or saved place are treated as the same building.
    static let sameBuildingDistance: Double = 30
    /// A fresh MapKit POI fetch waits until the user moves this far.
    static let poiRefetchDistance: Double = 50

    static func mergedPlaces(
        campus: CampusNicknameDictionary,
        saved: [SavedPlace],
        mapKit: [PointToScanPlace]
    ) -> [PointToScanPlace] {
        var places: [PointToScanPlace] = campus.places.map {
            PointToScanPlace(
                id: "campus:\($0.name)",
                name: $0.name,
                coordinate: $0.coordinate,
                source: .campus
            )
        }
        for place in saved {
            places.append(PointToScanPlace(
                id: "saved:\(place.id.uuidString)",
                name: place.displayName,
                coordinate: place.coordinate,
                source: .saved
            ))
        }
        let filtered = mapKit.filter { candidate in
            !places.contains { anchor in
                anchor.source != .mapKit
                    && GeoMath.distance(from: anchor.coordinate, to: candidate.coordinate) < sameBuildingDistance
            }
        }
        places.append(contentsOf: filtered)
        return places
    }

    /// Nearest place within range and bearing window; campus and saved before MapKit at equal distance.
    static func bestMatch(
        origin: GeoCoordinate,
        headingDegrees: Double,
        places: [PointToScanPlace]
    ) -> PointToScanPlace? {
        let matches = places.compactMap { place -> (PointToScanPlace, Double, Int)? in
            let metres = GeoMath.distance(from: origin, to: place.coordinate)
            guard metres.isFinite, metres <= maxDistance else { return nil }
            let absolute = GeoMath.bearing(from: origin, to: place.coordinate)
            let relative = RelativeBearing.from(heading: headingDegrees, toAbsoluteBearing: absolute)
            guard abs(relative.degrees) <= bearingWindow else { return nil }
            return (place, metres, sourceRank(place.source))
        }
        return matches.min { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
            return lhs.1 < rhs.1
        }?.0
    }

    static func shouldRefetchPOIs(from previous: GeoCoordinate?, to current: GeoCoordinate) -> Bool {
        guard let previous else { return true }
        return GeoMath.distance(from: previous, to: current) >= poiRefetchDistance
    }

    private static func sourceRank(_ source: PointToScanPlaceSource) -> Int {
        switch source {
        case .campus: 0
        case .saved: 1
        case .mapKit: 2
        }
    }
}