import Foundation
import Testing
@testable import AccessAble

struct ReportExclusionsTests {
    private let origin = GeoCoordinate(latitude: 33.7750, longitude: -84.4000)
    private let destination = GeoCoordinate(latitude: 33.7770, longitude: -84.3980)

    private func report(_ id: String, at coordinate: GeoCoordinate, area: [GeoCoordinate]? = nil) -> Report {
        Report(id: id, kind: .construction, coordinate: coordinate, area: area, createdAt: .now,
               expiresAt: .now.addingTimeInterval(3600), reporterID: "user-1")
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

    @Test
    func findsTheReportsARoutePasses() throws {
        let corner = GeoCoordinate(latitude: 33.7750, longitude: -84.3980)
        let route = try NavigationRoute(
            coordinates: [origin, corner, destination],
            steps: [
                RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Start", spokenInstruction: "Start"),
                RouteStep(kind: .arrive, coordinateIndex: 2, instruction: "Arrive", spokenInstruction: "Arrive"),
            ],
            estimatedDuration: 300
        )
        // About 10 m and 30 m north of the route's first leg.
        let near = report("near", at: GeoCoordinate(latitude: 33.77509, longitude: -84.3990))
        let far = report("far", at: GeoCoordinate(latitude: 33.77527, longitude: -84.3990))

        #expect(ReportExclusions.reports([near, far], passedBy: route) == [near])
    }
}
