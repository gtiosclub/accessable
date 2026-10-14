import Foundation

/// Geographic calculations for routing and the navigation tracker. Treats the Earth as a sphere.
///
/// Inputs are WGS84 degrees and assumed valid (`NavigationRoute` validates route data). A NaN or infinite
/// coordinate returns NaN instead of trapping. The sphere is within 0.5% of the WGS84 ellipsoid, far below GPS
/// error, and keeps projection onto a route closed-form. Route distances come from here too, so they agree with
/// that projection.
enum GeoMath {
    /// Mean Earth radius in metres.
    static let earthRadius = 6_371_008.8

    /// Great-circle distance in metres, from 0 up to `earthRadius * .pi`.
    static func distance(from start: GeoCoordinate, to end: GeoCoordinate) -> Double {
        let startLatitude = radians(start.latitude)
        let endLatitude = radians(end.latitude)
        let latitudeDelta = radians(end.latitude - start.latitude)
        let longitudeDelta = radians(end.longitude - start.longitude)

        // haversine stays accurate at walking distances, where the cosine formula loses precision
        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(startLatitude) * cos(endLatitude) * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        // rounding can push a just past 1 for opposite sides of the Earth;
        // sqrt(a) goes first because min returns its first argument when either is NaN, so NaN propagates.
        return 2 * earthRadius * asin(min(sqrt(a), 1))
    }

    /// Initial direction to head from `start` to reach `end`, in degrees clockwise from true north, 0..<360.
    /// Returns 0 when the points are the same.
    ///
    /// Undefined from a pole (every direction is south or north) and between antipodal points (every great
    /// circle joins them); the result there is finite but arbitrary. Rounding noise dominates once the points are
    /// under about a micrometre apart, so check `distance` first.
    static func bearing(from start: GeoCoordinate, to end: GeoCoordinate) -> Double {
        let startLatitude = radians(start.latitude)
        let endLatitude = radians(end.latitude)
        let longitudeDelta = radians(end.longitude - start.longitude)

        let y = sin(longitudeDelta) * cos(endLatitude)
        let x = cos(startLatitude) * sin(endLatitude) - sin(startLatitude) * cos(endLatitude) * cos(longitudeDelta)
        return normalizedBearing(atan2(y, x) * 180 / .pi)
    }

    /// Wraps any angle in degrees into 0..<360, never -0. `RelativeBearing` covers -180...180.
    /// NaN or infinite input returns NaN.
    static func normalizedBearing(_ angle: Double) -> Double {
        let wrapped = angle.truncatingRemainder(dividingBy: 360)
        let positive = wrapped < 0 ? wrapped + 360 : wrapped
        // -1e-14 rounds up to exactly 360, and -360 leaves -0
        return positive == 360 || positive == 0 ? 0 : positive
    }

    /// Metres from the first coordinate to each coordinate along the path: same count as `coordinates`,
    /// starts at 0, never decreases. Empty when `coordinates` is empty; NaN from the first non-finite
    /// coordinate on.
    static func cumulativeDistances(along coordinates: [GeoCoordinate]) -> [Double] {
        guard !coordinates.isEmpty else { return [] }
        var distances: [Double] = []
        distances.reserveCapacity(coordinates.count)
        distances.append(0)
        var total = 0.0
        for (start, end) in zip(coordinates, coordinates.dropFirst()) {
            total += distance(from: start, to: end)
            distances.append(total)
        }
        return distances
    }

    private static func radians(_ degrees: Double) -> Double {
        degrees * .pi / 180
    }
}
