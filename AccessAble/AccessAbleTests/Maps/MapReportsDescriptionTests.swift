import Foundation
import Testing
@testable import AccessAble

private let start = GeoCoordinate(latitude: 33.7750, longitude: -84.3990)

/// Straight north for 300 m.
private let route = try! NavigationRoute(
    coordinates: [start, TripWalk.destination(from: start, bearing: 0, distance: 300)],
    steps: [
        RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Start", spokenInstruction: "Start"),
        RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "Arrive"),
    ],
    estimatedDuration: 240
)

/// 20 m along the route, where the user is.
private let user = TripWalk.point(on: route, along: 20)

private func report(_ kind: ReportKind, at coordinate: GeoCoordinate) -> Report {
    Report(id: UUID().uuidString, kind: kind, coordinate: coordinate, createdAt: .now,
           expiresAt: .now.addingTimeInterval(3600), reporterID: "user-1")
}

private func text(
    _ reports: [Report], location: GeoCoordinate? = user, heading: Double? = 0,
    distances: DistanceFormatter = .metric
) -> String? {
    MapReportsDescription.text(reports, route: route, walked: 20, location: location, heading: heading,
                               distances: distances)
}

struct MapReportsDescriptionTests {
    @Test
    func noReportsSayNothing() {
        #expect(text([]) == nil)
    }

    /// The issue's example: one on the route ahead, one off it by the clock face from the way the user is going.
    @Test
    func onTheRouteAheadAndOffIt() {
        let ahead = report(.construction, at: TripWalk.point(on: route, along: 60))
        let off = report(.closedEntrance, at: TripWalk.destination(from: user, bearing: 60, distance: 120))
        #expect(text([off, ahead]) == "2 reports nearby: construction, 40 metres ahead on your route; "
            + "closed entrance, 120 metres at 2 o'clock.")
    }

    @Test
    func inTheUsersUnits() {
        let ahead = report(.blockedPath, at: TripWalk.point(on: route, along: 60))
        #expect(text([ahead], distances: .imperial) == "1 report nearby: blocked path, 125 feet ahead on your route.")
    }

    /// Behind the user isn't ahead on the route, so it is placed from where they are.
    @Test
    func aReportBehindIsPlacedFromTheUser() {
        let behind = report(.elevatorOut, at: start)
        #expect(text([behind]) == "1 report nearby: elevator out of service, 20 metres at 6 o'clock.")
    }

    @Test
    func withoutAHeadingOnlyTheDistance() {
        let off = report(.other, at: TripWalk.destination(from: user, bearing: 90, distance: 50))
        #expect(text([off], heading: nil) == "1 report nearby: reported problem, 50 metres away.")
    }

    @Test
    func withoutALocationOnlyTheKind() {
        let off = report(.other, at: TripWalk.destination(from: user, bearing: 90, distance: 50))
        #expect(text([off], location: nil) == "1 report nearby: reported problem.")
    }

    @Test
    func onlyTheNearestThree() {
        let reports = [150, 60, 120, 30, 90].map { report(.construction, at: TripWalk.point(on: route, along: $0)) }
        #expect(text(reports) == "5 reports nearby: construction, 10 metres ahead on your route; "
            + "construction, 40 metres ahead on your route; construction, 70 metres ahead on your route; and 2 more.")
    }
}
