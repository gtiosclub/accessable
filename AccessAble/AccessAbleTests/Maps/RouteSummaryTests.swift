import Foundation
import Testing
@testable import AccessAble

private let start = GeoCoordinate(latitude: 33.7750, longitude: -84.3990)
private let metresPerFoot = 0.3048

/// Straight north for `metres`, with a step of each kind in `kinds` between depart and arrive.
private func route(metres: Double, seconds: Double, kinds: [ManeuverKind] = []) throws -> NavigationRoute {
    let end = TripWalk.destination(from: start, bearing: 0, distance: metres)
    let steps = ([.depart] + kinds).map {
        RouteStep(kind: $0, coordinateIndex: 0, instruction: "Step", spokenInstruction: "Step")
    } + [RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "Arrive")]
    return try NavigationRoute(coordinates: [start, end], steps: steps, estimatedDuration: seconds)
}

private func crossings(_ count: Int) -> [RouteCrossing] {
    (0..<count).map { RouteCrossing(distanceAlongRoute: Double($0) * 20, control: .marked, audibleSignal: false) }
}

private func summary(
    metres: Double = 450 * metresPerFoot,
    seconds: Double = 360,
    kinds: [ManeuverKind] = [],
    crosswalks: Int = 0,
    distances: DistanceFormatter = .imperial
) throws -> String {
    RouteSummary(route: try route(metres: metres, seconds: seconds, kinds: kinds), crossings: crossings(crosswalks))
        .text(distances: distances)
}

struct RouteSummaryTests {
    @Test
    func theIssueExample() throws {
        #expect(try summary(kinds: [.turnLeft, .stairs, .turnRight, .turnLeft], crosswalks: 2)
            == "About 6 minutes, 450 feet. 3 turns, 1 flight of stairs, 2 crosswalks.")
    }

    @Test
    func turnsOnly() throws {
        #expect(try summary(kinds: [.turnLeft]) == "About 6 minutes, 450 feet. 1 turn.")
        #expect(try summary(kinds: [.turnLeft, .turnRight]) == "About 6 minutes, 450 feet. 2 turns.")
    }

    @Test
    func noTurns() throws {
        #expect(try summary(metres: 200 * metresPerFoot, seconds: 50) == "About 1 minute, 200 feet. No turns.")
    }

    @Test(arguments: [
        (ManeuverKind.stairs, "1 flight of stairs", "2 flights of stairs"),
        (.elevator, "1 elevator", "2 elevators"),
        (.escalator, "1 escalator", "2 escalators"),
    ])
    func eachFeatureSingularAndPlural(_ kind: ManeuverKind, _ one: String, _ two: String) throws {
        #expect(try summary(kinds: [kind]) == "About 6 minutes, 450 feet. No turns, \(one).")
        #expect(try summary(kinds: [kind, kind]) == "About 6 minutes, 450 feet. No turns, \(two).")
    }

    @Test
    func crosswalksSingularAndPlural() throws {
        #expect(try summary(crosswalks: 1) == "About 6 minutes, 450 feet. No turns, 1 crosswalk.")
        #expect(try summary(crosswalks: 2) == "About 6 minutes, 450 feet. No turns, 2 crosswalks.")
    }

    @Test
    func everythingTogetherInOrder() throws {
        // listed out of order so the text's order can't come from the steps'
        let kinds: [ManeuverKind] = [.escalator, .turnRight, .elevator, .stairs, .stairs, .turnLeft, .elevator]
        #expect(try summary(kinds: kinds, crosswalks: 3)
            == "About 6 minutes, 450 feet. 2 turns, 2 flights of stairs, 2 elevators, 1 escalator, 3 crosswalks.")
    }

    @Test
    func metresAndFeet() throws {
        #expect(try summary(metres: 300, seconds: 240, kinds: [.turnRight, .elevator], distances: .metric)
            == "About 4 minutes, 300 metres. 1 turn, 1 elevator.")
        #expect(try summary(metres: 1_840, seconds: 1_500, distances: .metric) == "About 25 minutes, 1.8 kilometres. No turns.")
        #expect(try summary(metres: 1_609.344, seconds: 1_200) == "About 20 minutes, 1 mile. No turns.")
    }

    @Test(arguments: [(0.0, 1), (20, 1), (89, 1), (90, 2), (149, 2), (330, 6)])
    func minutesRoundWithAOneMinuteFloor(_ seconds: Double, _ minutes: Int) throws {
        let unit = minutes == 1 ? "minute" : "minutes"
        #expect(try summary(seconds: seconds) == "About \(minutes) \(unit), 450 feet. No turns.")
    }

    @Test
    func summaryMentionsAnAvoidedConstructionReport() throws {
        let report = Report(
            id: "construction-1",
            kind: .construction,
            coordinate: start,
            createdAt: .now,
            expiresAt: .now.addingTimeInterval(60 * 60),
            reporterID: "test-user"
        )
        let destination = TripWalk.destination(from: start, bearing: 0, distance: 100)
        let route = try NavigationRoute(
            coordinates: [start, destination],
            steps: [
                RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Start", spokenInstruction: "Start"),
                RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "Arrive")
            ],
            estimatedDuration: 60,
            avoidedReports: [report]
        )
        let text = RouteSummary(route: route, crossings: []).text(distances: .metric)
        #expect(text == "About 1 minute, 100 metres. No turns. Avoiding 1 reported construction site.")
    }

    @Test
    func slightTurnsAndUTurnsCountButOtherStepsDoNot() throws {
        let counted = RouteSummary(route: try route(metres: 100, seconds: 60, kinds: [.slightLeft, .slightRight, .uTurn]),
                                   crossings: [])
        #expect(counted.turns == 3)

        let uncounted = RouteSummary(route: try route(metres: 100, seconds: 60,
                                                      kinds: [.straight, .cross, .enterBuilding, .exitBuilding]),
                                     crossings: [])
        #expect(uncounted.turns == 0)
        #expect(uncounted.text(distances: .metric) == "About 1 minute, 100 metres. No turns.")
    }
}
