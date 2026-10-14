import CoreLocation
import Foundation
import Testing
@testable import AccessAble

private let campus = GeoCoordinate(latitude: 33.775, longitude: -84.399)

private func isClose(_ actual: Double, _ expected: Double, within tolerance: Double) -> Bool {
    abs(actual - expected) <= tolerance
}

/// Smallest angle between two bearings in degrees, so 359.9 and 0.1 are 0.2 apart.
private func angularGap(_ first: Double, _ second: Double) -> Double {
    let gap = abs(first - second).truncatingRemainder(dividingBy: 360)
    return min(gap, 360 - gap)
}

struct GeoMathDistanceTests {
    struct KnownDistance: Sendable, CustomTestStringConvertible {
        let name: String
        let start: GeoCoordinate
        let end: GeoCoordinate
        let metres: Double
        var tolerance = 1e-6

        var testDescription: String { name }
    }

    // asin is ill-conditioned next to 1, so one rounding step in the haversine term costs about 0.2 m there.
    static let antipodalTolerance = 1.0

    static let knownDistances = [
        KnownDistance(name: "1° of latitude",
                      start: GeoCoordinate(latitude: 10, longitude: 20),
                      end: GeoCoordinate(latitude: 11, longitude: 20),
                      metres: SphereReference.metresPerDegree),
        KnownDistance(name: "1° of longitude on the equator",
                      start: GeoCoordinate(latitude: 0, longitude: 20),
                      end: GeoCoordinate(latitude: 0, longitude: 21),
                      metres: SphereReference.metresPerDegree),
        // Closed form for two points on one parallel. The great circle cuts inside the parallel, so this is about
        // 0.5 m short of half the equator value.
        KnownDistance(name: "1° of longitude at 60°",
                      start: GeoCoordinate(latitude: 60, longitude: 20),
                      end: GeoCoordinate(latitude: 60, longitude: 21),
                      metres: 2 * SphereReference.radius * asin(0.5 * sin(Double.pi / 360))),
        KnownDistance(name: "quarter meridian",
                      start: GeoCoordinate(latitude: 0, longitude: 0),
                      end: GeoCoordinate(latitude: 90, longitude: 0),
                      metres: Double.pi * SphereReference.radius / 2),
        KnownDistance(name: "antipodes on the equator",
                      start: GeoCoordinate(latitude: 0, longitude: 0),
                      end: GeoCoordinate(latitude: 0, longitude: 180),
                      metres: Double.pi * SphereReference.radius,
                      tolerance: antipodalTolerance),
        KnownDistance(name: "antipodes off the equator",
                      start: GeoCoordinate(latitude: 33.775, longitude: -84.399),
                      end: GeoCoordinate(latitude: -33.775, longitude: 95.601),
                      metres: Double.pi * SphereReference.radius,
                      tolerance: antipodalTolerance),
        KnownDistance(name: "across the dateline",
                      start: GeoCoordinate(latitude: 0, longitude: 179.5),
                      end: GeoCoordinate(latitude: 0, longitude: -179.5),
                      metres: SphereReference.metresPerDegree),
        KnownDistance(name: "1 cm along a meridian",
                      start: campus,
                      end: GeoCoordinate(latitude: campus.latitude + 0.01 / SphereReference.metresPerDegree,
                                         longitude: campus.longitude),
                      metres: 0.01),
    ]

    @Test(arguments: knownDistances)
    func matchesAnalyticValue(_ known: KnownDistance) {
        let distance = GeoMath.distance(from: known.start, to: known.end)
        #expect(isClose(distance, known.metres, within: known.tolerance))
    }

    @Test(arguments: [campus, GeoCoordinate(latitude: 90, longitude: 0), GeoCoordinate(latitude: -45, longitude: 180)])
    func isZeroForTheSamePoint(_ point: GeoCoordinate) {
        #expect(GeoMath.distance(from: point, to: point) == 0)
    }

    static let points = [
        campus,
        GeoCoordinate(latitude: 33.7765, longitude: -84.3963),
        GeoCoordinate(latitude: 0, longitude: 0),
        GeoCoordinate(latitude: 51.5, longitude: -0.12),
        GeoCoordinate(latitude: -33.87, longitude: 151.21),
        GeoCoordinate(latitude: 89.9, longitude: 45),
        GeoCoordinate(latitude: -60, longitude: -179.9),
    ]

    @Test
    func isSymmetric() {
        for start in Self.points {
            for end in Self.points {
                let forward = GeoMath.distance(from: start, to: end)
                let backward = GeoMath.distance(from: end, to: start)
                #expect(forward == backward, "\(start) ↔ \(end)")
            }
        }
    }

    @Test
    func satisfiesTheTriangleInequality() {
        for a in Self.points {
            for b in Self.points {
                for c in Self.points {
                    let direct = GeoMath.distance(from: a, to: c)
                    let viaB = GeoMath.distance(from: a, to: b) + GeoMath.distance(from: b, to: c)
                    #expect(direct <= viaB + 1e-6, "\(a) → \(b) → \(c)")
                }
            }
        }
    }

    // At Atlanta's latitude the ellipsoid's radii of curvature are 0.22% (east-west) to 0.25% (north-south) off
    // the mean radius, so 0.3% leaves margin without hiding a wrong formula.
    @Test(arguments: [
        GeoCoordinate(latitude: 33.776, longitude: -84.399),
        GeoCoordinate(latitude: 33.775, longitude: -84.395),
        GeoCoordinate(latitude: 33.7781, longitude: -84.4040),
        GeoCoordinate(latitude: 33.7710, longitude: -84.3920),
    ])
    func agreesWithCoreLocationOnCampus(_ end: GeoCoordinate) {
        let ellipsoid = CLLocation(latitude: campus.latitude, longitude: campus.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        let sphere = GeoMath.distance(from: campus, to: end)
        #expect(abs(sphere - ellipsoid) <= 0.003 * ellipsoid)
    }

    @Test(arguments: [Double.nan, .infinity])
    func propagatesNonFiniteInput(_ latitude: Double) {
        let invalid = GeoCoordinate(latitude: latitude, longitude: 0)
        #expect(GeoMath.distance(from: campus, to: invalid).isNaN)
        #expect(GeoMath.distance(from: invalid, to: campus).isNaN)
    }
}

struct GeoMathBearingTests {
    // Over 0.01° the great circle east or west starts within 0.003° of the parallel.
    @Test(arguments: [
        (GeoCoordinate(latitude: 33.785, longitude: -84.399), 0.0),
        (GeoCoordinate(latitude: 33.775, longitude: -84.389), 90.0),
        (GeoCoordinate(latitude: 33.765, longitude: -84.399), 180.0),
        (GeoCoordinate(latitude: 33.775, longitude: -84.409), 270.0),
    ])
    func pointsToTheCardinalDirections(_ end: GeoCoordinate, _ expected: Double) {
        #expect(angularGap(GeoMath.bearing(from: campus, to: end), expected) <= 0.01)
    }

    @Test(arguments: [
        GeoCoordinate(latitude: 33.7765, longitude: -84.3963),
        GeoCoordinate(latitude: 33.7741, longitude: -84.4012),
        GeoCoordinate(latitude: 33.7752, longitude: -84.3975),
    ])
    func backBearingIsOppositeOverShortDistances(_ end: GeoCoordinate) {
        let forward = GeoMath.bearing(from: campus, to: end)
        let back = GeoMath.bearing(from: end, to: campus)
        #expect(angularGap(back, forward + 180) <= 0.01)
    }

    @Test
    func crossesTheDateline() {
        let west = GeoCoordinate(latitude: 0, longitude: 179.9)
        let east = GeoCoordinate(latitude: 0, longitude: -179.9)
        #expect(isClose(GeoMath.bearing(from: west, to: east), 90, within: 1e-9))
        #expect(isClose(GeoMath.bearing(from: east, to: west), 270, within: 1e-9))
    }

    @Test(arguments: [campus, GeoCoordinate(latitude: -40, longitude: 10), GeoCoordinate(latitude: 0, longitude: 0)])
    func isZeroForTheSamePoint(_ point: GeoCoordinate) {
        #expect(GeoMath.bearing(from: point, to: point) == 0)
    }

    @Test(arguments: [Double.nan, .infinity])
    func propagatesNonFiniteInput(_ latitude: Double) {
        let invalid = GeoCoordinate(latitude: latitude, longitude: 0)
        #expect(GeoMath.bearing(from: campus, to: invalid).isNaN)
        #expect(GeoMath.bearing(from: invalid, to: campus).isNaN)
    }

    @Test(arguments: [
        (GeoCoordinate(latitude: 90, longitude: 0), campus),
        (GeoCoordinate(latitude: -90, longitude: 45), campus),
        (GeoCoordinate(latitude: 0, longitude: 0), GeoCoordinate(latitude: 0, longitude: 180)),
        (campus, GeoCoordinate(latitude: -33.775, longitude: 95.601)),
    ])
    func isFiniteInRangeWhereUndefined(_ start: GeoCoordinate, _ end: GeoCoordinate) {
        #expect((0..<360).contains(GeoMath.bearing(from: start, to: end)))
    }

    @Test
    func staysInRange() {
        for start in GeoMathDistanceTests.points {
            for end in GeoMathDistanceTests.points {
                let bearing = GeoMath.bearing(from: start, to: end)
                #expect((0..<360).contains(bearing), "\(start) → \(end) gave \(bearing)")
            }
        }
    }
}

struct GeoMathNormalizedBearingTests {
    @Test(arguments: [
        (-720.0, 0.0),
        (-360.0, 0.0),
        (-0.0, 0.0),
        (-1e-14, 0.0),
        (0.0, 0.0),
        (359.999999, 359.999999),
        (360.0, 0.0),
        (720.5, 0.5),
        (-90.0, 270.0),
    ])
    func wrapsInto0To360(_ angle: Double, _ expected: Double) {
        let normalized = GeoMath.normalizedBearing(angle)
        #expect(normalized == expected)
        #expect(normalized.sign == .plus)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func returnsNaNForNonFiniteInput(_ angle: Double) {
        #expect(GeoMath.normalizedBearing(angle).isNaN)
    }
}

struct GeoMathCumulativeDistanceTests {
    @Test
    func isEmptyForNoCoordinates() {
        #expect(GeoMath.cumulativeDistances(along: []).isEmpty)
    }

    @Test
    func isZeroForOneCoordinate() {
        #expect(GeoMath.cumulativeDistances(along: [campus]) == [0])
    }

    @Test
    func addsDegreesAlongTheEquator() {
        let path = (0...3).map { GeoCoordinate(latitude: 0, longitude: Double($0)) }
        let distances = GeoMath.cumulativeDistances(along: path)
        #expect(distances.count == 4)
        for (index, distance) in distances.enumerated() {
            #expect(isClose(distance, Double(index) * SphereReference.metresPerDegree, within: 1e-6))
        }
    }

    static let campusPath = [
        campus,
        GeoCoordinate(latitude: 33.7755, longitude: -84.3985),
        GeoCoordinate(latitude: 33.7755, longitude: -84.3985),
        GeoCoordinate(latitude: 33.7761, longitude: -84.3972),
        GeoCoordinate(latitude: 33.7749, longitude: -84.3968),
    ]

    @Test
    func startsAtZeroAndNeverDecreases() {
        let distances = GeoMath.cumulativeDistances(along: Self.campusPath)
        #expect(distances.count == Self.campusPath.count)
        #expect(distances.first == 0)
        for (previous, next) in zip(distances, distances.dropFirst()) {
            #expect(next >= previous)
        }
    }

    @Test
    func endsAtTheSumOfSegments() {
        let distances = GeoMath.cumulativeDistances(along: Self.campusPath)
        let segments = zip(Self.campusPath, Self.campusPath.dropFirst())
            .map { GeoMath.distance(from: $0, to: $1) }
        #expect(isClose(distances[distances.count - 1], segments.reduce(0, +), within: 1e-9))
    }

    @Test
    func isNaNFromTheFirstNonFiniteCoordinateOn() {
        var path = Self.campusPath
        path[2] = GeoCoordinate(latitude: .nan, longitude: -84.3985)
        let distances = GeoMath.cumulativeDistances(along: path)
        #expect(distances.count == path.count)
        #expect(distances[0].isFinite && distances[1].isFinite)
        for distance in distances[2...] {
            #expect(distance.isNaN)
        }
    }

    @Test
    func addsNothingForADuplicatePoint() {
        let distances = GeoMath.cumulativeDistances(along: Self.campusPath)
        #expect(distances[2] == distances[1])
    }
}
