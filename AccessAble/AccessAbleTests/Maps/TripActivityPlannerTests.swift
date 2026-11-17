import Foundation
import Testing
@testable import AccessAble

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let turnLeft = Maneuver(kind: .turnLeft, instruction: "Turn left onto Ferst Drive",
                                coordinate: GeoCoordinate(latitude: 33.775, longitude: -84.399))
private let arrive = Maneuver(kind: .arrive, instruction: "Arrive",
                              coordinate: GeoCoordinate(latitude: 33.776, longitude: -84.399))

private func trip(
    _ phase: TripPhase = .active, maneuver: Maneuver = turnLeft, distance: Double? = 45.72,
    remaining: Double? = 280, offRoute: Bool = false, at time: Date = start
) -> TripState {
    TripState(phase: phase, destinationName: "Clough Commons", nextManeuver: maneuver,
              distanceToNextManeuver: distance, distanceRemaining: remaining, isOffRoute: offRoute, updatedAt: time)
}

/// 280 m in 200 s: 1.4 m/s.
private func route() throws -> NavigationRoute {
    let origin = GeoCoordinate(latitude: 33.775, longitude: -84.399)
    return try NavigationRoute(coordinates: [origin, TripWalk.destination(from: origin, bearing: 0, distance: 280)],
                               steps: [
                                   RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Head north.",
                                             spokenInstruction: "Head north."),
                                   RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive",
                                             spokenInstruction: "You have arrived."),
                               ], estimatedDuration: 200)
}

struct TripActivityPlannerTests {
    /// The planner after the first active state, so each test starts with an activity running.
    private func running() -> TripActivityPlanner {
        var planner = TripActivityPlanner()
        _ = planner.action(for: trip(), route: nil, formatter: .imperial)
        return planner
    }

    @Test
    func startsOnTheFirstActiveState() {
        var planner = TripActivityPlanner()
        #expect(planner.action(for: trip(), route: nil, formatter: .imperial) == .start(
            destinationName: "Clough Commons",
            .init(status: .active, instruction: "Turn left onto Ferst Drive", distance: "150 ft",
                  spokenDistance: "150 feet", symbolName: "arrow.turn.up.left", arrival: nil),
            staleDate: start + TripActivityPlanner.staleAfter
        ))
    }

    @Test
    func noTripStartsNothing() {
        var planner = TripActivityPlanner()
        #expect(planner.action(for: .idle, route: nil, formatter: .imperial) == nil)
        #expect(planner.action(for: trip(.arrived), route: nil, formatter: .imperial) == nil)
        #expect(planner.finish() == nil)
    }

    @Test
    func lessThan25FeetIsNotAnUpdate() {
        var planner = running()
        #expect(planner.action(for: trip(distance: 45.72 - 7.5), route: nil, formatter: .imperial) == nil)
    }

    @Test
    func exactly25FeetIsAnUpdate() {
        // doubling and halving are exact, so the change is exactly the threshold
        let step = TripActivityPlanner.minimumDistanceChange
        var planner = TripActivityPlanner()
        _ = planner.action(for: trip(distance: 2 * step), route: nil, formatter: .imperial)
        #expect(planner.action(for: trip(distance: step.nextUp), route: nil, formatter: .imperial) == nil)
        guard case .update(let content, _) = planner.action(for: trip(distance: step), route: nil, formatter: .imperial)
        else {
            Issue.record("Expected an update")
            return
        }
        #expect(content.distance == "25 ft")
    }

    @Test
    func anUnchangedWrittenDistanceIsNotAnUpdate() {
        var planner = TripActivityPlanner()
        _ = planner.action(for: trip(distance: 1_609), route: nil, formatter: .imperial)
        // 40 m on, still "1 mi"
        #expect(planner.action(for: trip(distance: 1_569), route: nil, formatter: .imperial) == nil)
    }

    @Test
    func smallChangesAddUpTo25Feet() {
        var planner = running()
        #expect(planner.action(for: trip(distance: 42), route: nil, formatter: .imperial) == nil)
        let update = planner.action(for: trip(distance: 38), route: nil, formatter: .imperial)
        guard case .update(let content, _) = update else {
            Issue.record("Expected an update, got \(String(describing: update))")
            return
        }
        #expect(content.distance == "125 ft")
    }

    @Test
    func aNewStepIsAnUpdate() {
        var planner = running()
        let update = planner.action(for: trip(maneuver: arrive, distance: 45), route: nil, formatter: .imperial)
        #expect(update == .update(.init(status: .active, instruction: "Arrive", distance: "150 ft",
                                        spokenDistance: "150 feet", symbolName: "mappin.and.ellipse", arrival: nil),
                                  staleDate: start + TripActivityPlanner.staleAfter))
    }

    @Test
    func pausedUpdatesTheStatusWithoutADistance() {
        var planner = running()
        let update = planner.action(for: trip(.paused), route: nil, formatter: .imperial)
        #expect(update == .update(.init(status: .paused, instruction: "Turn left onto Ferst Drive",
                                        distance: nil, spokenDistance: nil,
                                        symbolName: "arrow.turn.up.left", arrival: nil),
                                  staleDate: start + TripActivityPlanner.staleAfter))
        #expect(planner.action(for: trip(.paused), route: nil, formatter: .imperial) == nil)
    }

    @Test
    func offRouteUpdatesTheStatusWithoutADistance() {
        var planner = running()
        let lost = Maneuver(kind: .turnLeft, instruction: "Off route. Finding a new route.",
                            coordinate: turnLeft.coordinate)
        let update = planner.action(for: trip(maneuver: lost, distance: nil, offRoute: true), route: nil,
                                    formatter: .imperial)
        #expect(update == .update(.init(status: .offRoute, instruction: "Off route. Finding a new route.",
                                        distance: nil, spokenDistance: nil, symbolName: "arrow.turn.up.left",
                                        arrival: nil),
                                  staleDate: start + TripActivityPlanner.staleAfter))
    }

    @Test
    func arrivalEndsWithTheArrivedStateAndIgnoresWhatFollows() {
        var planner = running()
        #expect(planner.action(for: trip(.arrived, maneuver: arrive), route: nil, formatter: .imperial) == .end(
            .init(status: .arrived, instruction: "You have arrived", distance: nil, spokenDistance: nil,
                  symbolName: "mappin.and.ellipse", arrival: nil),
            immediately: false
        ))
        #expect(planner.action(for: trip(.arrived, maneuver: arrive), route: nil, formatter: .imperial) == nil)
    }

    @Test
    func endingTheTripAfterArrivalClearsTheArrivedCard() {
        var planner = running()
        _ = planner.action(for: trip(.arrived, maneuver: arrive), route: nil, formatter: .imperial)
        guard case .end(let content, immediately: true) = planner.action(for: .idle, route: nil,
                                                                         formatter: .imperial)
        else {
            Issue.record("Expected an immediate end")
            return
        }
        #expect(content.status == .arrived)
        #expect(planner.action(for: .idle, route: nil, formatter: .imperial) == nil)
    }

    @Test
    func aSecondTripAfterArrivalStartsAgain() {
        var planner = running()
        _ = planner.action(for: trip(.arrived, maneuver: arrive), route: nil, formatter: .imperial)
        guard case .start = planner.action(for: trip(), route: nil, formatter: .imperial) else {
            Issue.record("Expected a new activity")
            return
        }
        // the new trip's own end, not the old arrived card's
        guard case .end(let content, immediately: true) = planner.finish() else {
            Issue.record("Expected an immediate end")
            return
        }
        #expect(content.status == .active)
    }

    @Test
    func aTripToANewDestinationStartsANewActivity() {
        var planner = running()
        var next = trip()
        next.destinationName = "Student Center"
        guard case .start(destinationName: "Student Center", _, _) = planner.action(for: next, route: nil,
                                                                                   formatter: .imperial)
        else {
            Issue.record("Expected a new activity")
            return
        }
    }

    @Test
    func noManeuverStartsNothing() {
        var planner = TripActivityPlanner()
        let state = TripState(phase: .active, destinationName: "Clough Commons", updatedAt: start)
        #expect(planner.action(for: state, route: nil, formatter: .imperial) == nil)
    }

    @Test
    func aFailedStartIsNotTriedAgainOnTheSameStep() {
        var planner = running()
        planner.startFailed()
        #expect(planner.action(for: trip(distance: 20), route: nil, formatter: .imperial) == nil)
    }

    @Test
    func aFailedStartIsTriedAgainAtANewStep() {
        var planner = running()
        planner.startFailed()
        guard case .start = planner.action(for: trip(maneuver: arrive), route: nil, formatter: .imperial) else {
            Issue.record("Expected another start")
            return
        }
    }

    @Test
    func aFailedStartIsTriedAgainAtANewStatus() {
        var planner = running()
        planner.startFailed()
        guard case .start = planner.action(for: trip(.paused), route: nil, formatter: .imperial) else {
            Issue.record("Expected another start")
            return
        }
    }

    @Test
    func aFailedStartIsTriedAgainOnANewTrip() {
        var planner = running()
        planner.startFailed()
        #expect(planner.action(for: .idle, route: nil, formatter: .imperial) == nil)
        guard case .start = planner.action(for: trip(), route: nil, formatter: .imperial) else {
            Issue.record("Expected another start")
            return
        }
    }

    @Test
    func aFailedStartIsTriedAgainOnTheSameStepInTheForeground() {
        var planner = running()
        planner.startFailed()
        planner.retryFailedStart()
        guard case .start = planner.action(for: trip(distance: 20), route: nil, formatter: .imperial) else {
            Issue.record("Expected another start")
            return
        }
    }

    @Test
    func endingTheTripEndsImmediately() {
        var planner = running()
        let action = planner.action(for: .idle, route: nil, formatter: .imperial)
        guard case .end(let content, let immediately) = action else {
            Issue.record("Expected an end, got \(String(describing: action))")
            return
        }
        #expect(content.instruction == "Turn left onto Ferst Drive")
        #expect(immediately)
        #expect(planner.finish() == nil)
    }

    @Test
    func aNewTripStartsAgain() {
        var planner = running()
        _ = planner.action(for: .idle, route: nil, formatter: .imperial)
        guard case .start = planner.action(for: trip(), route: nil, formatter: .imperial) else {
            Issue.record("Expected a new activity")
            return
        }
    }

    @Test
    func theStreamEndingEndsImmediately() {
        var planner = running()
        guard case .end(_, immediately: true) = planner.finish() else {
            Issue.record("Expected an immediate end")
            return
        }
    }

    @Test(arguments: [(DistanceFormatter.imperial, "150 ft", "150 feet"), (.metric, "50 m", "50 metres")])
    func distanceIsInTheUsersUnits(_ formatter: DistanceFormatter, _ written: String, _ spoken: String) {
        var planner = TripActivityPlanner()
        guard case .start(_, let content, _) = planner.action(for: trip(), route: nil, formatter: formatter) else {
            Issue.record("Expected a start")
            return
        }
        #expect(content.distance == written)
        #expect(content.spokenDistance == spoken)
    }

    @Test
    func arrivalIsAtTheRoutesWalkingSpeed() throws {
        var planner = TripActivityPlanner()
        guard case .start(_, let content, _) = planner.action(for: trip(remaining: 140), route: try route(),
                                                           formatter: .imperial)
        else {
            Issue.record("Expected a start")
            return
        }
        // 140 m at 1.4 m/s
        let arrival = try #require(content.arrival)
        #expect(abs(arrival.timeIntervalSince(start) - 100) < 0.5)
    }

    @Test
    func aRouteAfterItsStateAddsTheArrivalTime() throws {
        var planner = running()
        guard case .update(let content, _) = planner.action(for: trip(), route: try route(), formatter: .imperial) else {
            Issue.record("Expected an update")
            return
        }
        #expect(content.arrival != nil)
    }

    @Test
    func anArrivalTimeAMinuteLaterIsAnUpdate() throws {
        let route = try route()
        var planner = TripActivityPlanner()
        _ = planner.action(for: trip(), route: route, formatter: .imperial)
        // standing still
        #expect(planner.action(for: trip(at: start + 59), route: route, formatter: .imperial) == nil)
        guard case .update(let content, _) = planner.action(for: trip(at: start + 60), route: route,
                                                         formatter: .imperial)
        else {
            Issue.record("Expected an update")
            return
        }
        // 280 m at 1.4 m/s, from a minute later
        let arrival = try #require(content.arrival)
        #expect(abs(arrival.timeIntervalSince(start) - 260) < 0.5)
    }

    @Test(arguments: [false, true])
    func aStationaryUserIsStillUpdatedEachMinute(offRoute: Bool) {
        // no route, so no arrival time to move; off route there's no distance either
        let distance: Double? = offRoute ? nil : 45.72
        var planner = TripActivityPlanner()
        _ = planner.action(for: trip(distance: distance, offRoute: offRoute), route: nil, formatter: .imperial)
        #expect(planner.action(for: trip(distance: distance, offRoute: offRoute, at: start + 59), route: nil,
                               formatter: .imperial) == nil)
        guard case .update(_, let staleDate) = planner.action(
            for: trip(distance: distance, offRoute: offRoute, at: start + 60), route: nil, formatter: .imperial
        ) else {
            Issue.record("Expected an update")
            return
        }
        // well before the last update's stale date
        #expect(TripActivityPlanner.refreshInterval < TripActivityPlanner.staleAfter)
        #expect(staleDate == start + 60 + TripActivityPlanner.staleAfter)
    }

    @Test
    func pausedGoesStaleAndIsRefreshedEachMinute() {
        // a force quit while paused shouldn't leave the paused turn on the lock screen for hours
        var planner = TripActivityPlanner()
        guard case .start(_, _, let staleDate) = planner.action(for: trip(.paused), route: nil, formatter: .imperial)
        else {
            Issue.record("Expected a start")
            return
        }
        #expect(staleDate == start + TripActivityPlanner.staleAfter)
        #expect(planner.action(for: trip(.paused, distance: 20, at: start + 59), route: nil,
                               formatter: .imperial) == nil)
        guard case .update(let content, let refreshed) = planner.action(for: trip(.paused, at: start + 60),
                                                                        route: nil, formatter: .imperial)
        else {
            Issue.record("Expected an update")
            return
        }
        #expect(content.distance == nil)
        #expect(refreshed == start + 60 + TripActivityPlanner.staleAfter)
    }

    @Test
    func resumingMovesTheStaleDate() {
        var planner = TripActivityPlanner()
        _ = planner.action(for: trip(.paused), route: nil, formatter: .imperial)
        guard case .update(_, let staleDate) = planner.action(for: trip(at: start + 30), route: nil,
                                                              formatter: .imperial)
        else {
            Issue.record("Expected an update")
            return
        }
        #expect(staleDate == start + 30 + TripActivityPlanner.staleAfter)
    }

    @Test
    func noArrivalTimeWhilePaused() throws {
        var planner = TripActivityPlanner()
        guard case .start(_, let content, _) = planner.action(for: trip(.paused), route: try route(),
                                                           formatter: .imperial)
        else {
            Issue.record("Expected a start")
            return
        }
        #expect(content.arrival == nil)
    }
}
