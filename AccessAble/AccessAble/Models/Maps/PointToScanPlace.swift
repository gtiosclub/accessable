import Foundation

/// Where a point-to-scan result came from; campus and saved places outrank MapKit at about the same distance.
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
    /// Metres. A campus or saved place this much farther than the nearest match still wins over a MapKit one.
    static let preferredSourceSlack: Double = 15
    /// Degrees past the bearing window that count as turned away from a place.
    static let turnAwayMargin: Double = 25

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

    /// Nearest place within range and bearing window; a campus or saved place wins over MapKit only when it is
    /// within `preferredSourceSlack` of the nearest.
    static func bestMatch(
        origin: GeoCoordinate,
        headingDegrees: Double,
        places: [PointToScanPlace]
    ) -> PointToScanPlace? {
        let matches = places.compactMap { place -> (place: PointToScanPlace, metres: Double)? in
            let metres = GeoMath.distance(from: origin, to: place.coordinate)
            guard metres.isFinite, metres <= maxDistance else { return nil }
            guard abs(relativeBearing(origin: origin, headingDegrees: headingDegrees, to: place)) <= bearingWindow else {
                return nil
            }
            return (place, metres)
        }
        guard let nearest = matches.map(\.metres).min() else { return nil }
        return matches
            .filter { $0.metres <= nearest + preferredSourceSlack }
            .min { lhs, rhs in
                if lhs.place.source.isPreferred != rhs.place.source.isPreferred { return lhs.place.source.isPreferred }
                return lhs.metres < rhs.metres
            }?.place
    }

    /// Whether the heading is well outside the bearing window of `place`.
    static func isTurnedAway(origin: GeoCoordinate, headingDegrees: Double, from place: PointToScanPlace) -> Bool {
        let relative = relativeBearing(origin: origin, headingDegrees: headingDegrees, to: place)
        return abs(relative) > bearingWindow + turnAwayMargin
    }

    static func shouldRefetchPOIs(from previous: GeoCoordinate?, to current: GeoCoordinate) -> Bool {
        guard let previous else { return true }
        return GeoMath.distance(from: previous, to: current) >= poiRefetchDistance
    }

    private static func relativeBearing(
        origin: GeoCoordinate,
        headingDegrees: Double,
        to place: PointToScanPlace
    ) -> Double {
        let absolute = GeoMath.bearing(from: origin, to: place.coordinate)
        return RelativeBearing.from(heading: headingDegrees, toAbsoluteBearing: absolute).degrees
    }
}

private extension PointToScanPlaceSource {
    var isPreferred: Bool { self != .mapKit }
}
