import Foundation

/// Geographic calculations for routing and the navigation tracker. Treats the Earth as a sphere.
enum GeoMath {
    /// Mean Earth radius in metres.
    static let earthRadius = 6_371_008.8

    /// Great-circle distance in metres.
    static func distance(from start: GeoCoordinate, to end: GeoCoordinate) -> Double {
        let startLatitude = radians(start.latitude)
        let endLatitude = radians(end.latitude)
        let latitudeDelta = endLatitude - startLatitude
        let longitudeDelta = radians(end.longitude - start.longitude)

        // haversine stays accurate at walking distances, where the cosine formula loses precision
        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(startLatitude) * cos(endLatitude) * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        // rounding can push a just past 1 for opposite sides of the Earth
        return 2 * earthRadius * asin(min(1, sqrt(a)))
    }

    /// Metres from the first coordinate to each coordinate, following the path in order.
    /// Same count as `coordinates`; starts at 0. Empty when `coordinates` is empty.
    static func cumulativeDistances(along coordinates: [GeoCoordinate]) -> [Double] {
        guard !coordinates.isEmpty else { return [] }
        var distances: [Double] = [0]
        var total = 0.0
        for (start, end) in zip(coordinates, coordinates.dropFirst()) {
            total += distance(from: start, to: end)
            distances.append(total)
        }
        return distances
    }

    /// Direction to head from `start` to reach `end`, in degrees clockwise from true north, 0..<360.
    /// Returns 0 when the points are the same.
    static func bearing(from start: GeoCoordinate, to end: GeoCoordinate) -> Double {
        let startLatitude = radians(start.latitude)
        let endLatitude = radians(end.latitude)
        let longitudeDelta = radians(end.longitude - start.longitude)

        let y = sin(longitudeDelta) * cos(endLatitude)
        let x = cos(startLatitude) * sin(endLatitude) - sin(startLatitude) * cos(endLatitude) * cos(longitudeDelta)
        return normalizedBearing(atan2(y, x) * 180 / .pi)
    }

    /// Wraps any angle in degrees into 0..<360. `RelativeBearing` covers -180...180.
    static func normalizedBearing(_ angle: Double) -> Double {
        let wrapped = angle.truncatingRemainder(dividingBy: 360)
        let positive = wrapped < 0 ? wrapped + 360 : wrapped
        // -1e-14 rounds up to exactly 360, and -360 leaves -0
        return positive == 360 || positive == 0 ? 0 : positive
    }

    private static func radians(_ degrees: Double) -> Double {
        degrees * .pi / 180
    }
}
