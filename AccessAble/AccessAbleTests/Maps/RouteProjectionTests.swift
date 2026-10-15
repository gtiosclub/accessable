import Foundation
import Testing
@testable import AccessAble

private let metresPerDegree = SphereReference.metresPerDegree

private func isClose(_ actual: Double, _ expected: Double, within tolerance: Double) -> Bool {
    abs(actual - expected) <= tolerance
}

private func route(_ coordinates: [GeoCoordinate]) throws -> NavigationRoute {
    try NavigationRoute(
        coordinates: coordinates,
        steps: [RouteStep(kind: .arrive, coordinateIndex: coordinates.count - 1, instruction: "Arrive",
                          spokenInstruction: "Arrive")],
        estimatedDuration: 0
    )
}

private func point(_ latitude: Double, _ longitude: Double) -> GeoCoordinate {
    GeoCoordinate(latitude: latitude, longitude: longitude)
}

private let eastbound = [point(0, 0), point(0, 0.01)]

/// Foot latitude in degrees and cross-track metres for a point off the prime meridian. The foot is the point's unit
/// vector with its y component removed, and y itself is the sine of the cross-track angle.
private func offPrimeMeridian(_ latitude: Double, _ longitude: Double) -> (footLatitude: Double, crossTrack: Double) {
    let latitude = latitude * .pi / 180
    let longitude = longitude * .pi / 180
    return (atan2(sin(latitude), cos(latitude) * cos(longitude)) * 180 / .pi,
            asin(cos(latitude) * sin(longitude)) * SphereReference.radius)
}

private let meridianFoot = offPrimeMeridian(0.004, 0.001)

struct RouteProjectionAnalyticTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let coordinates: [GeoCoordinate]
        let point: GeoCoordinate
        let foot: GeoCoordinate
        /// Metres, from `SphereReference` so the expectation is independent of `GeoMath`.
        let along: Double
        let offset: Double
        var segmentIndex = 0

        var testDescription: String { name }
    }

    static let cases = [
        Case(name: "north of an eastbound equator segment is left", coordinates: eastbound,
             point: point(0.001, 0.005), foot: point(0, 0.005),
             along: 0.005 * metresPerDegree, offset: -0.001 * metresPerDegree),
        Case(name: "south of an eastbound equator segment is right", coordinates: eastbound,
             point: point(-0.001, 0.005), foot: point(0, 0.005),
             along: 0.005 * metresPerDegree, offset: 0.001 * metresPerDegree),
        Case(name: "north of a westbound equator segment is right", coordinates: [point(0, 0.01), point(0, 0)],
             point: point(0.001, 0.003), foot: point(0, 0.003),
             along: 0.007 * metresPerDegree, offset: 0.001 * metresPerDegree),
        Case(name: "east of a northbound meridian segment is right", coordinates: [point(0, 0), point(0.01, 0)],
             point: point(0.004, 0.001), foot: point(meridianFoot.footLatitude, 0),
             along: meridianFoot.footLatitude * metresPerDegree, offset: meridianFoot.crossTrack),
        Case(name: "east of a southbound meridian segment is left", coordinates: [point(0.01, 0), point(0, 0)],
             point: point(0.004, 0.001), foot: point(meridianFoot.footLatitude, 0),
             along: (0.01 - meridianFoot.footLatitude) * metresPerDegree, offset: -meridianFoot.crossTrack),
        Case(name: "on the segment", coordinates: eastbound,
             point: point(0, 0.003), foot: point(0, 0.003), along: 0.003 * metresPerDegree, offset: 0),
        // 1 m then 5 cm along the equator, where acos-based angles would lose most of their digits.
        Case(name: "left of a 1 m segment", coordinates: shortSegments,
             point: point(0.2 / metresPerDegree, 0.5 / metresPerDegree), foot: point(0, 0.5 / metresPerDegree),
             along: 0.5, offset: -0.2),
        Case(name: "right of a 5 cm segment", coordinates: shortSegments,
             point: point(-0.01 / metresPerDegree, 1.02 / metresPerDegree), foot: point(0, 1.02 / metresPerDegree),
             along: 1.02, offset: 0.01, segmentIndex: 1),
    ]

    static let shortSegments = [point(0, 0), point(0, 1 / metresPerDegree), point(0, 1.05 / metresPerDegree)]

    @Test(arguments: cases)
    func matchesTheSphere(_ known: Case) throws {
        let projection = try route(known.coordinates).projection(of: known.point)
        #expect(projection.originalCoordinate == known.point)
        #expect(projection.segmentIndex == known.segmentIndex)
        #expect(isClose(projection.coordinate.latitude, known.foot.latitude, within: 1e-11))
        #expect(isClose(projection.coordinate.longitude, known.foot.longitude, within: 1e-11))
        #expect(isClose(projection.distanceAlongRoute, known.along, within: 1e-6))
        #expect(isClose(projection.sideOffset, known.offset, within: 1e-6))
    }
}

struct RouteProjectionCaseTests {
    @Test
    func clampsBeforeTheStart() throws {
        let fix = point(0.001, -0.002)
        let projection = try route(eastbound).projection(of: fix)
        #expect(projection.originalCoordinate == fix)
        #expect(projection.coordinate == eastbound[0])
        #expect(projection.segmentIndex == 0)
        #expect(projection.distanceAlongRoute == 0)
        #expect(projection.sideOffset == -GeoMath.distance(from: fix, to: eastbound[0]))
    }

    @Test
    func clampsPastTheEnd() throws {
        let route = try route(eastbound)
        let fix = point(-0.001, 0.012)
        let projection = route.projection(of: fix)
        #expect(projection.originalCoordinate == fix)
        #expect(projection.coordinate == eastbound[1])
        #expect(projection.segmentIndex == 0)
        #expect(projection.distanceAlongRoute == route.totalDistance)
        #expect(projection.sideOffset == GeoMath.distance(from: fix, to: eastbound[1]))
    }

    @Test
    func takesTheCornerOnTheOuterSideOfATurn() throws {
        // East, then a left turn north; the point is south-east of the corner, right of both legs.
        let route = try route([point(0, 0), point(0, 0.01), point(0.01, 0.01)])
        let fix = point(-0.001, 0.011)
        let projection = route.projection(of: fix)
        #expect(projection.originalCoordinate == fix)
        #expect(projection.coordinate == route.coordinates[1])
        #expect(projection.segmentIndex == 0)
        #expect(projection.distanceAlongRoute == route.cumulativeDistances[1])
        #expect(projection.sideOffset == GeoMath.distance(from: fix, to: route.coordinates[1]))
        #expect(projection.sideOffset > 0)
    }

    static let leftTurn = [point(0, 0), point(0, 0.01), point(0.01, 0.01)]

    @Test
    func snapsToAVertexWithinAMillimetre() throws {
        let route = try route(Self.leftTurn)
        let nearCorner = point(0, 0.01 - 0.0005 / metresPerDegree)
        let projection = route.projection(of: nearCorner)
        #expect(projection.originalCoordinate == nearCorner)
        #expect(projection.coordinate == route.coordinates[1])
        #expect(projection.distanceAlongRoute == route.cumulativeDistances[1])
    }

    @Test
    func snapsToASegmentStart() throws {
        let route = try route(Self.leftTurn)
        let fix = point(-0.0001, 0.0005 / metresPerDegree)
        let projection = route.projection(of: fix)
        #expect(projection.originalCoordinate == fix)
        #expect(projection.coordinate == route.coordinates[0])
        #expect(projection.segmentIndex == 0)
        #expect(projection.distanceAlongRoute == 0)
        #expect(projection.sideOffset == GeoMath.distance(from: fix, to: route.coordinates[0]))
    }

    @Test
    func snapsWhenTheFootIsNearAVertexButThePointIsFarOff() throws {
        let route = try route(Self.leftTurn)
        // About 11 m south of the route, with its foot 0.5 mm before the corner.
        let fix = point(-0.0001, 0.01 - 0.0005 / metresPerDegree)
        let projection = route.projection(of: fix)
        #expect(projection.originalCoordinate == fix)
        #expect(projection.coordinate == route.coordinates[1])
        #expect(projection.segmentIndex == 0)
        #expect(projection.distanceAlongRoute == route.cumulativeDistances[1])
        #expect(projection.sideOffset == GeoMath.distance(from: fix, to: route.coordinates[1]))
    }

    @Test
    func doesNotSnapTwoMillimetresFromAVertex() throws {
        let route = try route(Self.leftTurn)
        let projection = route.projection(of: point(0, 0.01 - 0.002 / metresPerDegree))
        #expect(projection.coordinate != route.coordinates[1])
        #expect(projection.segmentIndex == 0)
        #expect(projection.distanceAlongRoute < route.cumulativeDistances[1])
        #expect(isClose(projection.distanceAlongRoute, route.cumulativeDistances[1] - 0.002, within: 1e-6))
    }

    @Test
    func progressNeverDecreasesAcrossTheSnapDistance() throws {
        let route = try route(Self.leftTurn)
        // Every 0.25 mm from 3 mm before the corner to 3 mm after it.
        var previous = 0.0
        for step in -12...12 {
            let metres = Double(step) * 0.00025
            let walked = metres < 0 ? point(0, 0.01 + metres / metresPerDegree) : point(metres / metresPerDegree, 0.01)
            let progress = route.projection(of: walked).distanceAlongRoute
            #expect(progress >= previous, "\(metres) m")
            previous = progress
        }
    }

    @Test
    func clampsToTheStartOfTheSearchedSegments() throws {
        let route = try route(Self.leftTurn)
        // South-west of the corner, beside the first leg but before the start of the second.
        let fix = point(-0.0001, 0.005)
        let projection = route.projection(of: fix, segments: 1..<2)
        #expect(projection.originalCoordinate == fix)
        #expect(projection.coordinate == route.coordinates[1])
        #expect(projection.segmentIndex == 1)
        #expect(projection.distanceAlongRoute == route.cumulativeDistances[1])
        #expect(projection.sideOffset == -GeoMath.distance(from: fix, to: route.coordinates[1]))
    }

    @Test
    func clampsToTheEndOfTheSearchedSegments() throws {
        let route = try route(Self.leftTurn)
        // North-east of the corner, beside the second leg but past the end of the first.
        let fix = point(0.005, 0.0101)
        let projection = route.projection(of: fix, segments: 0..<1)
        #expect(projection.originalCoordinate == fix)
        #expect(projection.coordinate == route.coordinates[1])
        #expect(projection.segmentIndex == 0)
        #expect(projection.distanceAlongRoute == route.cumulativeDistances[1])
        #expect(projection.sideOffset == -GeoMath.distance(from: fix, to: route.coordinates[1]))
    }

    static let withZeroLengthSegment = [point(0, 0), point(0, 0.01), point(0, 0.01), point(0.01, 0.01)]

    @Test
    func skipsPastAZeroLengthSegment() throws {
        let route = try route(Self.withZeroLengthSegment)
        let projection = route.projection(of: point(0.005, 0.0105))
        #expect(projection.segmentIndex == 2)
        #expect(isClose(projection.distanceAlongRoute, 0.015 * metresPerDegree, within: 1e-6))
        #expect(isClose(projection.sideOffset, 0.0005 * metresPerDegree, within: 1e-6))
    }

    @Test
    func treatsAZeroLengthSegmentAsAPointWithNoSide() throws {
        let route = try route(Self.withZeroLengthSegment)
        // North-west of the point, which would be left of any eastbound or northbound travel.
        let fix = point(0.001, 0.009)
        let projection = route.projection(of: fix, segments: 1..<2)
        #expect(projection.coordinate == route.coordinates[1])
        #expect(projection.segmentIndex == 1)
        #expect(projection.distanceAlongRoute == route.cumulativeDistances[1])
        #expect(projection.sideOffset == GeoMath.distance(from: fix, to: route.coordinates[1]))
    }

    @Test
    func resolvesATieToTheLowestSegment() throws {
        let route = try route(Self.withZeroLengthSegment)
        let projection = route.projection(of: route.coordinates[1])
        #expect(projection.segmentIndex == 0)
        #expect(projection.distanceAlongRoute == route.cumulativeDistances[1])
    }

    static let outAndBack = [point(0, 0), point(0, 0.01), point(0, 0)]

    @Test
    func resolvesOverlappingLegsToTheOutboundOne() throws {
        let projection = try route(Self.outAndBack).projection(of: point(0.001, 0.004))
        #expect(projection.segmentIndex == 0)
        #expect(isClose(projection.distanceAlongRoute, 0.004 * metresPerDegree, within: 1e-6))
        #expect(isClose(projection.sideOffset, -0.001 * metresPerDegree, within: 1e-6))
    }

    @Test
    func searchesOnlyTheGivenSegments() throws {
        let projection = try route(Self.outAndBack).projection(of: point(0.001, 0.004), segments: 1..<2)
        #expect(projection.segmentIndex == 1)
        #expect(isClose(projection.distanceAlongRoute, 0.016 * metresPerDegree, within: 1e-6))
        #expect(isClose(projection.sideOffset, 0.001 * metresPerDegree, within: 1e-6))
    }

    @Test(arguments: [
        point(.nan, 0.005),
        point(0.001, .nan),
        point(.infinity, 0.005),
        point(0.001, -.infinity),
    ])
    func propagatesNonFiniteInput(_ point: GeoCoordinate) throws {
        let projection = try route(Self.outAndBack).projection(of: point, segments: 1..<2)
        // Bit patterns, since NaN never equals itself.
        #expect(projection.originalCoordinate.latitude.bitPattern == point.latitude.bitPattern)
        #expect(projection.originalCoordinate.longitude.bitPattern == point.longitude.bitPattern)
        #expect(projection.coordinate.latitude.bitPattern == point.latitude.bitPattern)
        #expect(projection.coordinate.longitude.bitPattern == point.longitude.bitPattern)
        #expect(projection.segmentIndex == 1)
        #expect(projection.distanceAlongRoute.isNaN)
        #expect(projection.sideOffset.isNaN)
    }

    // Exit tests are unavailable on iOS, so the preconditions on `segments` (non-empty, in bounds) are not tested.
}

struct RouteProjectionPropertyTests {
    static let campusRoute = [
        point(33.7750, -84.3990),
        point(33.7755, -84.3985),
        point(33.7761, -84.3972),
        point(33.7749, -84.3968),
        point(33.7745, -84.3980),
    ]

    /// A grid over the route and its surroundings, up to about 100 m off it.
    static let campusPoints = stride(from: 33.7740, through: 33.7766, by: 0.0005).flatMap { latitude in
        stride(from: -84.3996, through: -84.3962, by: 0.0008).map { point(latitude, $0) }
    }

    @Test
    func agreesWithADensifiedRoute() throws {
        let route = try route(Self.campusRoute)
        // Linear steps in latitude and longitude stray under 1 mm from the great circle over these segments, so
        // the reference does not share the projection's vector math.
        var samples: [GeoCoordinate] = []
        for (start, end) in zip(Self.campusRoute, Self.campusRoute.dropFirst()) {
            let steps = Int((GeoMath.distance(from: start, to: end) / 0.01).rounded(.up))
            for step in 0...steps {
                let fraction = Double(step) / Double(steps)
                samples.append(point(start.latitude + fraction * (end.latitude - start.latitude),
                                     start.longitude + fraction * (end.longitude - start.longitude)))
            }
        }

        for point in Self.campusPoints {
            var nearest = samples[0]
            var nearestDistance = Double.infinity
            for sample in samples {
                let distance = GeoMath.distance(from: point, to: sample)
                if distance < nearestDistance {
                    nearest = sample
                    nearestDistance = distance
                }
            }
            let projection = route.projection(of: point)
            #expect(isClose(abs(projection.sideOffset), nearestDistance, within: 0.01), "\(point)")
            #expect(GeoMath.distance(from: projection.coordinate, to: nearest) <= 0.01, "\(point)")
        }
    }

    @Test
    func gridCoversEverySegmentSideAndFootKind() throws {
        let route = try route(Self.campusRoute)
        var segmentIndices = Set<Int>()
        var hasLeft = false
        var hasRight = false
        var hasVertexFoot = false
        var hasInteriorFoot = false
        for point in Self.campusPoints {
            let projection = route.projection(of: point)
            segmentIndices.insert(projection.segmentIndex)
            hasLeft = hasLeft || projection.sideOffset < 0
            hasRight = hasRight || projection.sideOffset > 0
            if route.coordinates.contains(projection.coordinate) {
                hasVertexFoot = true
            } else {
                hasInteriorFoot = true
            }
        }
        #expect(segmentIndices == Set(0..<route.coordinates.count - 1))
        #expect(hasLeft && hasRight)
        #expect(hasVertexFoot && hasInteriorFoot)
    }

    @Test
    func staysOnItsSegment() throws {
        let route = try route(Self.campusRoute)
        for point in Self.campusPoints {
            let projection = route.projection(of: point)
            let start = route.coordinates[projection.segmentIndex]
            let end = route.coordinates[projection.segmentIndex + 1]
            let fromStart = GeoMath.distance(from: start, to: projection.coordinate)
            let toEnd = GeoMath.distance(from: projection.coordinate, to: end)
            #expect(isClose(fromStart + toEnd, GeoMath.distance(from: start, to: end), within: 1e-6), "\(point)")
            #expect(isClose(projection.distanceAlongRoute,
                            route.cumulativeDistances[projection.segmentIndex] + fromStart, within: 1e-6), "\(point)")
            #expect(projection.distanceAlongRoute >= 0 && projection.distanceAlongRoute <= route.totalDistance,
                    "\(point)")
        }
    }

    @Test
    func offsetIsTheDistanceToTheProjection() throws {
        let route = try route(Self.campusRoute)
        for point in Self.campusPoints {
            let projection = route.projection(of: point)
            #expect(abs(projection.sideOffset) == GeoMath.distance(from: point, to: projection.coordinate), "\(point)")
        }
    }

    @Test
    func keepsTheOriginalGPSCoordinate() throws {
        let route = try route(Self.campusRoute)
        var sawSnappedAwayFromGPS = false
        for point in Self.campusPoints {
            let projection = route.projection(of: point)
            #expect(projection.originalCoordinate == point, "\(point)")
            if projection.coordinate != point {
                sawSnappedAwayFromGPS = true
            }
        }
        #expect(sawSnappedAwayFromGPS)
    }

    @Test
    func searchesTheWholeRouteByDefault() throws {
        let route = try route(Self.campusRoute)
        for point in Self.campusPoints {
            #expect(route.projection(of: point) == route.projection(of: point, segments: 0..<4), "\(point)")
        }
    }

    @Test
    func matchesCumulativeDistancesAtVertices() throws {
        let route = try route(Self.campusRoute)
        for (index, vertex) in route.coordinates.enumerated() {
            let projection = route.projection(of: vertex)
            #expect(projection.originalCoordinate == vertex)
            #expect(projection.coordinate == vertex)
            #expect(projection.segmentIndex == max(index - 1, 0))
            #expect(projection.distanceAlongRoute == route.cumulativeDistances[index])
            #expect(projection.sideOffset == 0)
        }
    }

    @Test
    func progressNeverDecreasesAlongTheRoute() throws {
        let route = try route(Self.campusRoute)
        var previous = 0.0
        for (start, end) in zip(Self.campusRoute, Self.campusRoute.dropFirst()) {
            for step in 0...20 {
                let fraction = Double(step) / 20
                let walked = point(start.latitude + fraction * (end.latitude - start.latitude),
                                   start.longitude + fraction * (end.longitude - start.longitude))
                let progress = route.projection(of: walked).distanceAlongRoute
                #expect(progress >= previous, "\(walked)")
                previous = progress
            }
        }
    }
}
