import Foundation
import Testing
@testable import AccessAble

struct ReportExclusionsTests {
    private let origin = GeoCoordinate(latitude: 33.7750, longitude: -84.4000)
    private let destination = GeoCoordinate(latitude: 33.7770, longitude: -84.3980)

    private func report(_ id: String, at coordinate: GeoCoordinate, area: [GeoCoordinate]? = nil) -> Report {
        Report(id: id, kind: .construction, coordinate: coordinate, area: area, createdAt: .now,
               expiresAt: .now.addingTimeInterval(3600))
    }

    /// A square about `side` metres across, with its south-west corner at `corner`.
    private func square(at corner: GeoCoordinate, side: Double) -> [GeoCoordinate] {
        let latitude = side / 111_195
        let longitude = latitude / cos(corner.latitude * .pi / 180)
        return [
            corner,
            GeoCoordinate(latitude: corner.latitude + latitude, longitude: corner.longitude),
            GeoCoordinate(latitude: corner.latitude + latitude, longitude: corner.longitude + longitude),
            GeoCoordinate(latitude: corner.latitude, longitude: corner.longitude + longitude),
        ]
    }

    /// An L-shaped walk turns at a corner about 140 m off the straight line between its ends.
    @Test
    func excludesAReportAtTheCornerOfABendingRoute() {
        let corner = report("corner", at: GeoCoordinate(latitude: 33.7750, longitude: -84.3980))

        let exclusions = ReportExclusions.make(from: [corner], origin: origin, destination: destination)

        #expect(exclusions.options.excludeLocations == [corner.coordinate])
        #expect(exclusions.excluded == [corner])
    }

    @Test
    func excludesAnAreaAsAPolygonWithoutItsClosingPoint() {
        let area = square(at: GeoCoordinate(latitude: 33.7760, longitude: -84.3990), side: 20)
        let closed = report("area", at: area[0], area: area + [area[0]])

        let exclusions = ReportExclusions.make(from: [closed], origin: origin, destination: destination)

        #expect(exclusions.options.excludePolygons == [area])
        #expect(exclusions.options.excludeLocations.isEmpty)
    }

    @Test
    func excludesAnAreaOfFewerThanThreeDistinctPointsAsItsPoint() {
        let point = GeoCoordinate(latitude: 33.7760, longitude: -84.3990)
        let line = report("line", at: point, area: [point, point, GeoCoordinate(latitude: 33.7761, longitude: -84.3990)])

        let exclusions = ReportExclusions.make(from: [line], origin: origin, destination: destination)

        #expect(exclusions.options.excludeLocations == [point])
        #expect(exclusions.options.excludePolygons.isEmpty)
    }

    /// Valhalla refuses the whole request over its limit, so the reports furthest from the trip are left out.
    @Test
    func capsPointsKeepingTheNearest() {
        let reports = (0..<51).map { index in
            report("\(index)", at: GeoCoordinate(latitude: 33.7750 - Double(index) * 0.0001, longitude: -84.4000))
        }

        let exclusions = ReportExclusions.make(from: reports.reversed(), origin: origin, destination: destination)

        #expect(exclusions.options.excludeLocations.count == ReportExclusions.maximumLocations)
        #expect(Set(exclusions.excluded) == Set(reports.prefix(ReportExclusions.maximumLocations)))
    }

    @Test
    func leavesOutAPolygonPastThePerimeterBudget() {
        let small = report("small", at: origin, area: square(at: origin, side: 20))
        let huge = report("huge", at: origin, area: square(at: origin, side: 1_500))

        let exclusions = ReportExclusions.make(from: [huge, small], origin: origin, destination: destination)

        #expect(exclusions.excluded == [small])
        #expect(exclusions.options.excludePolygons == [square(at: origin, side: 20)])
    }

    @Test
    func keepsTheCallersOwnExclusionsAndCountsThemInTheCap() {
        let own = (0..<ReportExclusions.maximumLocations).map { _ in origin }
        let options = RouteOptions(walkingSpeed: 0.8, excludeLocations: own)

        let exclusions = ReportExclusions.make(
            from: [report("one", at: destination)], origin: origin, destination: destination, adding: options
        )

        #expect(exclusions.options == options)
        #expect(exclusions.excluded.isEmpty)
    }

    /// East about 185 m to a corner, then north about 222 m to `destination`.
    private func lRoute() throws -> NavigationRoute {
        try NavigationRoute(
            coordinates: [origin, GeoCoordinate(latitude: 33.7750, longitude: -84.3980), destination],
            steps: [
                RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Start", spokenInstruction: "Start"),
                RouteStep(kind: .arrive, coordinateIndex: 2, instruction: "Arrive", spokenInstruction: "Arrive"),
            ],
            estimatedDuration: 300
        )
    }

    // About 10 m and 30 m north of the first leg, halfway along it.
    private var near: Report { report("near", at: GeoCoordinate(latitude: 33.77509, longitude: -84.3990)) }
    private var far: Report { report("far", at: GeoCoordinate(latitude: 33.77527, longitude: -84.3990)) }

    @Test
    func findsTheReportsARoutePasses() throws {
        // each read of `near` is a new report, created at a new time
        let near = near
        #expect(ReportExclusions.reports([near, far], passedBy: try lRoute()) == [near])
    }

    @Test
    func findsHowFarAlongARoutePassesAReport() throws {
        let route = try lRoute()
        let along = try #require(ReportExclusions.distanceAlong(route, passing: near, from: 0))
        #expect(abs(along - 92.5) < 1)
        #expect(ReportExclusions.distanceAlong(route, passing: far, from: 0) == nil)
    }

    @Test
    func aReportAlreadyPassedIsNotAhead() throws {
        let route = try lRoute()
        #expect(ReportExclusions.distanceAlong(route, passing: near, from: 100) == nil)
        // on the second leg, so the first isn't searched at all
        #expect(ReportExclusions.distanceAlong(route, passing: near, from: 200) == nil)
    }

    @Test
    func findsAReportAheadOnALaterLeg() throws {
        let route = try lRoute()
        // About 9 m east of the second leg, halfway along it.
        let beside = report("beside", at: GeoCoordinate(latitude: 33.7760, longitude: -84.39790))
        let along = try #require(ReportExclusions.distanceAlong(route, passing: beside, from: 50))
        #expect(abs(along - (route.cumulativeDistances[1] + 111.2)) < 1)
    }

    @Test
    func anAreaCornerNearTheRouteCounts() throws {
        let area = report("area", at: far.coordinate, area: [far.coordinate, near.coordinate,
                                                             GeoCoordinate(latitude: 33.77527, longitude: -84.3989)])
        let along = try #require(ReportExclusions.distanceAlong(try lRoute(), passing: area, from: 0))
        #expect(abs(along - 92.5) < 1)
    }

    /// An area reported at its centre, between two latitudes and two longitudes.
    private func rectangle(south: Double, north: Double, west: Double, east: Double) -> Report {
        report("rectangle", at: GeoCoordinate(latitude: (south + north) / 2, longitude: (west + east) / 2), area: [
            GeoCoordinate(latitude: south, longitude: west), GeoCoordinate(latitude: north, longitude: west),
            GeoCoordinate(latitude: north, longitude: east), GeoCoordinate(latitude: south, longitude: east),
        ])
    }

    /// About 100 m across the first leg, 55 m south and 100 m north of it: its centre and corners are all over 20 m
    /// from the route.
    private var crossed: Report { rectangle(south: 33.7745, north: 33.7759, west: -84.3995, east: -84.39842) }

    @Test
    func aRouteThroughTheMiddleOfAnAreaPassesIt() throws {
        let crossed = crossed
        #expect(ReportExclusions.reports([crossed], passedBy: try lRoute()) == [crossed])
    }

    @Test
    func passingAnAreaIsMeasuredWhereTheRouteEntersIt() throws {
        let route = try lRoute()
        let boundary = GeoMath.distance(from: origin, to: GeoCoordinate(latitude: 33.7750, longitude: -84.3995))
        let along = try #require(ReportExclusions.distanceAlong(route, passing: crossed, from: 0))
        #expect(abs(along - boundary) < 1)
        // already inside it, so it is passed right where the user is
        let inside = try #require(ReportExclusions.distanceAlong(route, passing: crossed, from: boundary + 20))
        #expect(abs(inside - (boundary + 20)) < 1)
        // out the other side, so it is behind
        #expect(ReportExclusions.distanceAlong(route, passing: crossed, from: boundary + 120) == nil)
    }

    @Test
    func aRouteJustOutsideAnAreaDoesNotPassIt() throws {
        let route = try lRoute()
        // its south edge about 20 m north of the first leg
        let beside = rectangle(south: 33.77518, north: 33.7760, west: -84.3995, east: -84.39842)
        #expect(ReportExclusions.reports([beside], passedBy: route).isEmpty)
        #expect(ReportExclusions.distanceAlong(route, passing: beside, from: 0) == nil)
    }

    @Test
    func aRouteStartingInsideAnAreaPassesItAtTheStart() throws {
        let route = try lRoute()
        let around = rectangle(south: 33.7745, north: 33.7759, west: -84.4005, east: -84.39942)
        #expect(ReportExclusions.reports([around], passedBy: route) == [around])
        #expect(ReportExclusions.distanceAlong(route, passing: around, from: 0) == 0)
    }

    @Test
    func passingAnAreaOnALaterLegIsMeasuredAlongTheWholeRoute() throws {
        let route = try lRoute()
        // 55 m north of the corner to 100 m north of it, 90 m west to 30 m east of the second leg: its centre and
        // corners are all over 20 m from the route
        let later = rectangle(south: 33.7755, north: 33.7762, west: -84.3990, east: -84.3977)
        #expect(ReportExclusions.reports([later], passedBy: route) == [later])
        let corner = GeoCoordinate(latitude: 33.7750, longitude: -84.3980)
        let boundary = GeoMath.distance(from: origin, to: corner)
            + GeoMath.distance(from: corner, to: GeoCoordinate(latitude: 33.7755, longitude: -84.3980))
        let along = try #require(ReportExclusions.distanceAlong(route, passing: later, from: 0))
        #expect(abs(along - boundary) < 1)
        let fromTheCorner = try #require(ReportExclusions.distanceAlong(route, passing: later, from: boundary - 20))
        #expect(abs(fromTheCorner - boundary) < 1)
    }

    @Test
    func aRouteEntirelyInsideAnAreaPassesItWhereverTheUserIs() throws {
        let route = try lRoute()
        let around = rectangle(south: 33.7740, north: 33.7780, west: -84.4010, east: -84.3970)
        #expect(ReportExclusions.reports([around], passedBy: route) == [around])
        #expect(ReportExclusions.distanceAlong(route, passing: around, from: 0) == 0)
        #expect(ReportExclusions.distanceAlong(route, passing: around, from: 100) == 100)
    }

    @Test
    func anAreaIsNeverPassedAtAPointBeyondTheEndOfTheRoute() throws {
        let route = try lRoute()
        let atTheEnd = rectangle(south: 33.7765, north: 33.7775, west: -84.3985, east: -84.3975)
        let along = try #require(ReportExclusions.distanceAlong(route, passing: atTheEnd, from: route.totalDistance + 50))
        #expect(along == route.totalDistance)
    }

    @Test
    func anAreaWithItsClosingPointIsCrossedLikeOneWithout() throws {
        let route = try lRoute()
        let ring = try #require(crossed.area)
        let closed = report("closed", at: crossed.coordinate, area: ring + [ring[0]])
        #expect(ReportExclusions.reports([closed], passedBy: route) == [closed])
        let open = try #require(ReportExclusions.distanceAlong(route, passing: crossed, from: 0))
        #expect(ReportExclusions.distanceAlong(route, passing: closed, from: 0) == open)
    }

    @Test
    func anAreaOfFewerThanThreeDistinctPointsIsNotEntered() throws {
        let route = try lRoute()
        // each point is over 50 m from the route, though the line between them crosses it
        let south = GeoCoordinate(latitude: 33.7745, longitude: -84.3990)
        let north = GeoCoordinate(latitude: 33.7759, longitude: -84.3990)
        let aside = GeoCoordinate(latitude: 33.7745, longitude: -84.39925)
        for area in [[south, north], [south, north, north]] {
            let line = report("line", at: aside, area: area)
            #expect(ReportExclusions.reports([line], passedBy: route).isEmpty)
            #expect(ReportExclusions.distanceAlong(route, passing: line, from: 0) == nil)
        }
    }

    @Test
    func aRouteVertexOnAnAreasEdgeTouchesIt() throws {
        let route = try lRoute()
        // its west edge runs north from the route's corner, which is as far as the route reaches it
        let touching = rectangle(south: 33.7745, north: 33.7755, west: -84.3980, east: -84.3970)
        #expect(ReportExclusions.reports([touching], passedBy: route) == [touching])
        let along = try #require(ReportExclusions.distanceAlong(route, passing: touching, from: 0))
        let corner = GeoCoordinate(latitude: 33.7750, longitude: -84.3980)
        #expect(abs(along - GeoMath.distance(from: origin, to: corner)) < 1)
    }

    @Test
    func aRouteThroughTheNotchOfAConcaveAreaDoesNotPassIt() throws {
        let route = try lRoute()
        // an L along the south and east of the route's corner, with the route in the notch to its north-west
        let l = report("l", at: GeoCoordinate(latitude: 33.7753, longitude: -84.3965), area: [
            GeoCoordinate(latitude: 33.7740, longitude: -84.3990), GeoCoordinate(latitude: 33.7740, longitude: -84.3966),
            GeoCoordinate(latitude: 33.7766, longitude: -84.3966), GeoCoordinate(latitude: 33.7766, longitude: -84.3970),
            GeoCoordinate(latitude: 33.7744, longitude: -84.3970), GeoCoordinate(latitude: 33.7744, longitude: -84.3990),
        ])
        #expect(ReportExclusions.reports([l], passedBy: route).isEmpty)
        #expect(ReportExclusions.distanceAlong(route, passing: l, from: 0) == nil)
    }
}
