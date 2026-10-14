import Foundation
import simd

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

    /// Closest point to `point` on the path through `coordinates`, searching only `segments`. Segment `i` joins
    /// `coordinates[i]` to `coordinates[i + 1]`, and `cumulativeDistances` must be
    /// `cumulativeDistances(along: coordinates)`. `NavigationRoute.projection(of:segments:)` states the contract.
    static func project(
        _ point: GeoCoordinate,
        onto coordinates: [GeoCoordinate],
        cumulativeDistances: [Double],
        segments: Range<Int>
    ) -> RouteProjection {
        precondition(!segments.isEmpty, "No segments to project onto")
        precondition(segments.lowerBound >= 0 && segments.upperBound < coordinates.count,
                     "Segments \(segments) out of bounds for \(coordinates.count) coordinates")
        guard point.latitude.isFinite, point.longitude.isFinite else {
            return RouteProjection(coordinate: point, segmentIndex: segments.lowerBound,
                                   distanceAlongRoute: .nan, sideOffset: .nan)
        }

        let target = unitVector(point)
        var bestIndex = segments.lowerBound
        var best = SegmentProjection(foot: .start, angle: .infinity, isLeft: false)
        var start = unitVector(coordinates[segments.lowerBound])
        for index in segments {
            let end = unitVector(coordinates[index + 1])
            let candidate = project(target, from: start, to: end)
            // strict, so ties keep the lowest segment index
            if candidate.angle < best.angle {
                best = candidate
                bestIndex = index
            }
            start = end
        }

        let coordinate: GeoCoordinate
        let distanceAlongRoute: Double
        switch best.foot {
        case .start:
            coordinate = coordinates[bestIndex]
            distanceAlongRoute = cumulativeDistances[bestIndex]
        case .end:
            coordinate = coordinates[bestIndex + 1]
            distanceAlongRoute = cumulativeDistances[bestIndex + 1]
        case .interior(let foot):
            coordinate = self.coordinate(from: foot)
            distanceAlongRoute = cumulativeDistances[bestIndex]
                + earthRadius * angle(between: unitVector(coordinates[bestIndex]), and: foot)
        }
        // `distance` rather than the cross-track angle, so `abs(sideOffset)` matches it exactly.
        let offset = distance(from: point, to: coordinate)
        return RouteProjection(coordinate: coordinate, segmentIndex: bestIndex,
                               distanceAlongRoute: distanceAlongRoute, sideOffset: best.isLeft ? -offset : offset)
    }

    /// About 1 mm of arc in radians. Segments shorter than this have a normal made mostly of rounding noise, and
    /// feet this close to a vertex snap to it so progress there equals `cumulativeDistances` exactly.
    private static let pointTolerance = 1e-3 / earthRadius

    private enum Foot {
        case start
        case end
        case interior(SIMD3<Double>)
    }

    private struct SegmentProjection {
        let foot: Foot
        /// Radians from the projected point to its foot.
        let angle: Double
        let isLeft: Bool
    }

    /// Projects unit vector `point` onto the arc from `start` to `end`, all on the unit sphere.
    private static func project(
        _ point: SIMD3<Double>,
        from start: SIMD3<Double>,
        to end: SIMD3<Double>
    ) -> SegmentProjection {
        let normal = cross(start, end)
        // No direction of travel, so no side.
        guard length(normal) > pointTolerance else {
            return SegmentProjection(foot: .start, angle: angle(between: point, and: start), isLeft: false)
        }
        let unitNormal = normalize(normal)
        // The normal points to the left of travel, since start × end follows the right-hand rule.
        let side = dot(point, unitNormal)
        let isLeft = side > 0
        // Can be NaN when the point is at or near a pole of the great circle; the arc test then fails and the
        // nearer endpoint wins.
        let foot = normalize(point - side * unitNormal)

        if dot(cross(start, foot), unitNormal) >= 0, dot(cross(foot, end), unitNormal) >= 0 {
            if angle(between: start, and: foot) <= pointTolerance {
                return SegmentProjection(foot: .start, angle: angle(between: point, and: start), isLeft: isLeft)
            }
            if angle(between: foot, and: end) <= pointTolerance {
                return SegmentProjection(foot: .end, angle: angle(between: point, and: end), isLeft: isLeft)
            }
            return SegmentProjection(foot: .interior(foot), angle: angle(between: point, and: foot), isLeft: isLeft)
        }
        let toStart = angle(between: point, and: start)
        let toEnd = angle(between: point, and: end)
        return toStart <= toEnd
            ? SegmentProjection(foot: .start, angle: toStart, isLeft: isLeft)
            : SegmentProjection(foot: .end, angle: toEnd, isLeft: isLeft)
    }

    /// Radians between two unit vectors. atan2 stays accurate for the tiny angles of short segments, where acos of
    /// the dot product rounds to 0.
    private static func angle(between first: SIMD3<Double>, and second: SIMD3<Double>) -> Double {
        atan2(length(cross(first, second)), dot(first, second))
    }

    /// Earth-centred, Earth-fixed position on the unit sphere: x through (0, 0), z through the north pole.
    private static func unitVector(_ coordinate: GeoCoordinate) -> SIMD3<Double> {
        let latitude = radians(coordinate.latitude)
        let longitude = radians(coordinate.longitude)
        return SIMD3(cos(latitude) * cos(longitude), cos(latitude) * sin(longitude), sin(latitude))
    }

    private static func coordinate(from vector: SIMD3<Double>) -> GeoCoordinate {
        GeoCoordinate(latitude: atan2(vector.z, hypot(vector.x, vector.y)) * 180 / .pi,
                      longitude: atan2(vector.y, vector.x) * 180 / .pi)
    }

    private static func radians(_ degrees: Double) -> Double {
        degrees * .pi / 180
    }
}
