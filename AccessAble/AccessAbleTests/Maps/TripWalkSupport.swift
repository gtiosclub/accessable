import Foundation
@testable import AccessAble

/// Deterministic GPS fixes for walking a route, so tracker tests replay exactly.
enum TripWalk {
    static let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Metres along a route at each fix when walking from `from` to `to` at `speed` metres per second, one fix every
    /// `interval` seconds. Starts at `from` and stops at the last fix not past `to`.
    static func distances(from: Double, to: Double, speed: Double = 1.4, interval: TimeInterval = 1) -> [Double] {
        let step = speed * interval
        return (0...Int(((to - from) / step).rounded(.down))).map { from + Double($0) * step }
    }

    /// One fix per point, `interval` seconds apart from `start`.
    static func fixes(at coordinates: [GeoCoordinate], start: Date = start, interval: TimeInterval = 1,
                      accuracy: Double = 5) -> [LocationSample] {
        coordinates.enumerated().map { index, coordinate in
            LocationSample(coordinate: coordinate, horizontalAccuracy: accuracy,
                           timestamp: start.addingTimeInterval(Double(index) * interval))
        }
    }

    /// One fix per `(along, lateral)` pair, as `point(on:along:lateral:)`.
    static func fixes(on route: NavigationRoute, path: [(along: Double, lateral: Double)], start: Date = start,
                      interval: TimeInterval = 1, accuracy: Double = 5) -> [LocationSample] {
        fixes(at: path.map { point(on: route, along: $0.along, lateral: $0.lateral) },
              start: start, interval: interval, accuracy: accuracy)
    }

    /// The point `along` metres along the route, then `lateral` metres to the right of travel (negative is left).
    /// Before the start or past the end it extends the first or last segment.
    static func point(on route: NavigationRoute, along: Double, lateral: Double = 0) -> GeoCoordinate {
        let distances = route.cumulativeDistances
        let index = (0..<route.coordinates.count - 1).last { distances[$0] <= along } ?? 0
        let start = route.coordinates[index]
        let bearing = GeoMath.bearing(from: start, to: route.coordinates[index + 1])
        let onRoute = destination(from: start, bearing: bearing, distance: along - distances[index])
        return lateral == 0 ? onRoute : destination(from: onRoute, bearing: bearing + 90, distance: lateral)
    }

    /// The point `distance` metres from `start` along the great circle with initial `bearing` in degrees.
    /// A negative distance goes the opposite way.
    static func destination(from start: GeoCoordinate, bearing: Double, distance: Double) -> GeoCoordinate {
        let angle = distance / SphereReference.radius
        let course = bearing * .pi / 180
        let latitude = start.latitude * .pi / 180
        let longitude = start.longitude * .pi / 180
        let endLatitude = asin(sin(latitude) * cos(angle) + cos(latitude) * sin(angle) * cos(course))
        let endLongitude = longitude + atan2(sin(course) * sin(angle) * cos(latitude),
                                             cos(angle) - sin(latitude) * sin(endLatitude))
        return GeoCoordinate(latitude: endLatitude * 180 / .pi, longitude: endLongitude * 180 / .pi)
    }
}

/// Seeded linear congruential generator, so noisy walks are the same on every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        // Knuth's MMIX constants
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
