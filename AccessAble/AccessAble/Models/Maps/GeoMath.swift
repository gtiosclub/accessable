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

    private static func radians(_ degrees: Double) -> Double {
        degrees * .pi / 180
    }
}
