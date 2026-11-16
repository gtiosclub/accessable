import Foundation
import Testing
@testable import AccessAble

private let start = GeoCoordinate(latitude: 33.7750, longitude: -84.3990)
private let end = TripWalk.destination(from: start, bearing: 0, distance: 200)

/// Straight north 200 m.
private func northRoute() throws -> NavigationRoute {
    try NavigationRoute(coordinates: [start, end], steps: [
        RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Walk north.", spokenInstruction: "Walk north."),
        RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "Arrive"),
    ], estimatedDuration: 160)
}

/// A crossing `lateral` metres right of the route (negative is left) at `along`, which may be past either end.
private func crossing(along: Double, lateral: Double = 0, control: CampusCrossing.Control = .marked,
                      audibleSignal: Bool = false) throws -> CampusCrossing {
    CampusCrossing(coordinate: TripWalk.point(on: try northRoute(), along: along, lateral: lateral),
                   control: control, audibleSignal: audibleSignal)
}

struct RouteCrossingsTests {
    @Test(arguments: [(0.0, true), (2, true), (-2, true), (4, false), (-4, false)])
    func onlyCrossingsOnTheRouteAreKept(lateral: Double, isKept: Bool) throws {
        let crossings = RouteCrossings.along(try northRoute(), crossings: [try crossing(along: 100, lateral: lateral)])

        #expect(crossings.count == (isKept ? 1 : 0))
        if isKept { #expect(abs((crossings.first?.distanceAlongRoute ?? 0) - 100) < 0.01) }
    }

    @Test(arguments: [(-15.0, false), (-2, true), (202, true), (215, false)])
    func crossingsPastTheEndsAreKeptOnlyNearThem(along: Double, isKept: Bool) throws {
        let crossings = RouteCrossings.along(try northRoute(), crossings: [try crossing(along: along)])

        #expect(crossings.count == (isKept ? 1 : 0))
    }

    @Test
    func nodeAndWayCentreOfOneCrossingMergeWithTheBetterAttributes() throws {
        let node = try crossing(along: 80, control: .marked)
        let wayCentre = try crossing(along: 83, lateral: 1, control: .signals, audibleSignal: true)

        let crossings = RouteCrossings.along(try northRoute(), crossings: [wayCentre, node])

        #expect(crossings.count == 1)
        let merged = try #require(crossings.first)
        #expect(abs(merged.distanceAlongRoute - 80) < 0.01)
        #expect(merged.control == .signals)
        #expect(merged.audibleSignal)
    }

    @Test(arguments: [
        (CampusCrossing.Control.unmarked, CampusCrossing.Control.unknown, CampusCrossing.Control.unknown),
        (.unknown, .marked, .marked),
        (.signals, .unmarked, .signals),
    ])
    func mergedCrossingKeepsTheMostInformativeControl(_ first: CampusCrossing.Control,
                                                      _ second: CampusCrossing.Control,
                                                      _ expected: CampusCrossing.Control) throws {
        let crossings = RouteCrossings.along(try northRoute(), crossings: [
            try crossing(along: 120, control: first), try crossing(along: 126, control: second),
        ])

        #expect(crossings.map(\.control) == [expected])
    }

    @Test
    func separateCrossingsAreKeptInRouteOrder() throws {
        let crossings = RouteCrossings.along(try northRoute(), crossings: [
            try crossing(along: 130, control: .unmarked), try crossing(along: 100, control: .signals),
        ])

        #expect(crossings.map(\.control) == [.signals, .unmarked])
        #expect(crossings.map { ($0.distanceAlongRoute * 10).rounded() / 10 } == [100, 130])
    }

    @Test
    func noCrossingsGiveNone() throws {
        #expect(RouteCrossings.along(try northRoute(), crossings: []).isEmpty)
    }

    @Test
    func campusFixtureRouteUsesOneMarkedCrossing() throws {
        let url = try #require(Bundle.main.url(forResource: "valhalla-route-sample", withExtension: "json"))
        let route = try ValhallaGeometryDecoder.decodeRoute(from: Data(contentsOf: url))

        let crossings = RouteCrossings.along(route, crossings: CampusCrossings.all)

        // the route goes through a marked crosswalk about 404 m along; the next nearest crossing, about 15 m beside
        // the route near 501 m, is one it passes rather than uses
        #expect(crossings.count == 1)
        let crosswalk = try #require(crossings.first)
        #expect(abs(crosswalk.distanceAlongRoute - 403.7) < 1)
        #expect(crosswalk.control == .marked)
        #expect(!crosswalk.audibleSignal)
    }
}

/// The bundled export from Scripts/CampusCrossings.
struct CampusCrossingsTests {
    @Test
    func decodeReadsEachControlAndTheAudibleSignal() throws {
        let json = """
        {
          "source": "OpenStreetMap contributors via Overpass API",
          "license": "ODbL (https://www.openstreetmap.org/copyright)",
          "exportDate": "2026-10-16T22:36:45Z",
          "crossings": [
            {"latitude": 33.1, "longitude": -84.1, "control": "signals", "audibleSignal": true},
            {"latitude": 33.2, "longitude": -84.2, "control": "signals", "audibleSignal": false},
            {"latitude": 33.3, "longitude": -84.3, "control": "marked", "audibleSignal": false},
            {"latitude": 33.4, "longitude": -84.4, "control": "unmarked", "audibleSignal": false},
            {"latitude": 33.5, "longitude": -84.5, "control": "unknown", "audibleSignal": false},
            {"latitude": 33.6, "longitude": -84.6, "control": "raised_table", "audibleSignal": false}
          ]
        }
        """

        let crossings = try CampusCrossings.decode(Data(json.utf8))

        #expect(crossings.map(\.control) == [.signals, .signals, .marked, .unmarked, .unknown, .unknown])
        #expect(crossings.map(\.audibleSignal) == [true, false, false, false, false, false])
        #expect(crossings.first?.coordinate == GeoCoordinate(latitude: 33.1, longitude: -84.1))
    }

    @Test
    func bundledCampusDataLoads() {
        let crossings = CampusCrossings.all

        #expect(crossings.count > 600)
        // inside the export's box around campus
        #expect(crossings.allSatisfy { crossing in
            (33.770...33.782).contains(crossing.coordinate.latitude)
                && (-84.408 ... -84.388).contains(crossing.coordinate.longitude)
        })
        #expect(crossings.contains { $0.control == .signals && $0.audibleSignal })
        #expect(crossings.contains { $0.control == .unmarked })
    }
}
