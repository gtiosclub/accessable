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

/// Fixes like a phone's while walking outdoors, for checking the tracker against more than clean geometry.
enum FieldWalk {
    /// Where the user really is once a second, and which way they walk: along the route `lateral` metres to the right
    /// of it (negative is left) up to `leaving`, then `seconds` more straight on at `bearing`. Without `leaving`, the
    /// whole route.
    static func path(on route: NavigationRoute, lateral: Double = 0, leaving: Double? = nil, bearing: Double = 0,
                     seconds: Int = 0, speed: Double = 1.4) -> [(coordinate: GeoCoordinate, course: Double)] {
        var points: [(coordinate: GeoCoordinate, course: Double)] = []
        let end = leaving ?? route.totalDistance
        for along in TripWalk.distances(from: 0, to: end, speed: speed) {
            let here = TripWalk.point(on: route, along: along, lateral: lateral)
            let ahead = TripWalk.point(on: route, along: along + 0.5, lateral: lateral)
            points.append((here, GeoMath.bearing(from: here, to: ahead)))
        }
        guard let last = points.last, seconds > 0 else { return points }
        for second in 1...seconds {
            let ahead = TripWalk.destination(from: last.coordinate, bearing: bearing, distance: speed * Double(second))
            points.append((ahead, bearing))
        }
        return points
    }

    /// One fix a second along `path`. The position error drifts rather than jumps, as GPS error does, with a standard
    /// deviation of half the reported accuracy, which itself swings slowly across `accuracy`. Each course is off by up
    /// to about half its reported accuracy, drawn from `courseAccuracy`, and the speed by about 0.2 m/s.
    static func fixes(along path: [(coordinate: GeoCoordinate, course: Double)], accuracy: ClosedRange<Double>,
                      courseAccuracy: ClosedRange<Double>, seed: UInt64,
                      start: Date = TripWalk.start) -> [LocationSample] {
        var generator = SeededGenerator(seed: seed)
        func normal() -> Double {
            let u1 = max(Double.random(in: 0..<1, using: &generator), 1e-12)
            let u2 = Double.random(in: 0..<1, using: &generator)
            return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        }
        // each second's error keeps 85 % of the last
        let memory = 0.85
        var east = 0.0
        var north = 0.0
        return path.enumerated().map { index, point in
            let swing = 0.5 + 0.5 * sin(Double(index) / 7)
            let horizontal = accuracy.lowerBound + (accuracy.upperBound - accuracy.lowerBound) * swing
            let spread = sqrt(1 - memory * memory) * horizontal / 2
            east = memory * east + spread * normal()
            north = memory * north + spread * normal()
            let shifted = TripWalk.destination(from: TripWalk.destination(from: point.coordinate, bearing: 90,
                                                                         distance: east),
                                               bearing: 0, distance: north)
            let course = Double.random(in: courseAccuracy, using: &generator)
            return LocationSample(coordinate: shifted, horizontalAccuracy: horizontal,
                                  timestamp: start.addingTimeInterval(Double(index)),
                                  speed: max(1.4 + 0.2 * normal(), 0.1),
                                  course: GeoMath.normalizedBearing(point.course + course / 2 * normal()),
                                  courseAccuracy: course)
        }
    }
}
