import Foundation
import Testing
@testable import AccessAble

private typealias Event = RouteProgressTracker.GuidanceEvent

private func fixtureRoute() throws -> NavigationRoute {
    let url = try #require(Bundle.main.url(forResource: "valhalla-route-sample", withExtension: "json"))
    return try ValhallaGeometryDecoder.decodeRoute(from: Data(contentsOf: url))
}

/// Straight legs from campus, with a step at the start of each leg and an arrival at the end.
private func syntheticRoute(
    _ legs: [(bearing: Double, length: Double, kind: ManeuverKind, spoken: String)]
) throws -> NavigationRoute {
    var coordinates = [GeoCoordinate(latitude: 33.775, longitude: -84.399)]
    var steps: [RouteStep] = []
    for leg in legs {
        steps.append(RouteStep(kind: leg.kind, coordinateIndex: coordinates.count - 1, instruction: leg.spoken,
                               spokenInstruction: leg.spoken))
        coordinates.append(TripWalk.destination(from: coordinates[coordinates.count - 1], bearing: leg.bearing,
                                                distance: leg.length))
    }
    steps.append(RouteStep(kind: .arrive, coordinateIndex: coordinates.count - 1, instruction: "Arrive",
                           spokenInstruction: "You have arrived."))
    return try NavigationRoute(coordinates: coordinates, steps: steps, estimatedDuration: 0)
}

/// North 300 m, then right for 100 m.
private func cornerRoute() throws -> NavigationRoute {
    try syntheticRoute([(0, 300, .depart, "Walk north."), (90, 100, .turnRight, "Turn right.")])
}

private func onRoute(_ distances: [Double]) -> [(along: Double, lateral: Double)] {
    distances.map { ($0, 0) }
}

/// North 100 m, then `bearing` for 100 m.
private func turnRoute(_ bearing: Double) throws -> NavigationRoute {
    try syntheticRoute([(0, 100, .depart, "Walk north."), (bearing, 100, .turnRight, "Turn right.")])
}

/// Fixes walking straight on past vertex 1, 1.4 m further at each fix, moved by `offset` metres along and right.
private func straightOn(past route: NavigationRoute, count: Int, start: Date,
                        offset: (Int) -> (along: Double, lateral: Double) = { _ in (0, 0) }) -> [LocationSample] {
    let vertex = route.coordinates[1]
    let heading = GeoMath.bearing(from: route.coordinates[0], to: vertex)
    return TripWalk.fixes(at: (1...count).map { index in
        let noise = offset(index)
        let ahead = TripWalk.destination(from: vertex, bearing: heading, distance: 1.4 * Double(index) + noise.along)
        return TripWalk.destination(from: ahead, bearing: heading + 90, distance: noise.lateral)
    }, start: start)
}

/// An event and the index of the fix that produced it, with distances to 0.1 m so expectations can be written out.
private struct Logged: Equatable {
    let fix: Int
    let event: Event

    init(_ fix: Int, _ event: Event) {
        self.fix = fix
        switch event {
        case let .prepare(step, distance):
            self.event = .prepare(step: step, distance: (distance * 10).rounded() / 10)
        case let .missedTurn(step, distance):
            self.event = .missedTurn(step: step, distanceBack: (distance * 10).rounded() / 10)
        default:
            self.event = event
        }
    }
}

/// Which cues fired, ignoring when and at what distance.
private func cueKinds(_ events: [Logged]) -> [Event] {
    events.map { logged in
        switch logged.event {
        case let .prepare(step, _): .prepare(step: step, distance: 0)
        case let .missedTurn(step, _): .missedTurn(step: step, distanceBack: 0)
        default: logged.event
        }
    }
}

private struct Walk {
    var tracker: RouteProgressTracker
    private(set) var logged: [Logged] = []
    private(set) var states: [RouteProgressTracker.Progress] = []

    init(_ route: NavigationRoute) {
        tracker = RouteProgressTracker(route: route, startedAt: TripWalk.start)
    }

    var fixCount: Int { states.count }
    /// The next timestamp for a walk with one fix per second.
    var nextTime: Date { TripWalk.start.addingTimeInterval(Double(fixCount)) }

    mutating func feed(_ fixes: [LocationSample], emitsCues: Bool = true) {
        for fix in fixes {
            let update = tracker.update(with: fix, emitsCues: emitsCues)
            logged += update.events.map { Logged(fixCount, $0) }
            states.append(update.state)
        }
    }

    mutating func feed(_ path: [(along: Double, lateral: Double)], accuracy: Double = 5, emitsCues: Bool = true) {
        feed(TripWalk.fixes(on: tracker.route, path: path, start: nextTime, accuracy: accuracy), emitsCues: emitsCues)
    }
}

private func noisyFixtureWalk(_ route: NavigationRoute) -> [(along: Double, lateral: Double)] {
    var generator = SeededGenerator(seed: 2026)
    return TripWalk.distances(from: 0, to: route.totalDistance).enumerated().map { index, along in
        // 6 s multipath bursts on the long leg, away from any turn
        let burst = (150..<156).contains(index) || (220..<226).contains(index) ? 15.0 : 0
        let alongNoise = 5 * Double.random(in: -1...1, using: &generator)
        let lateralNoise = 8 * Double.random(in: -1...1, using: &generator)
        return (along + alongNoise, burst + lateralNoise)
    }
}

struct RouteProgressTrackerTests {
    @Test
    func startsAtTheFirstStepAfterDeparture() throws {
        let route = try fixtureRoute()
        let state = RouteProgressTracker(route: route, startedAt: TripWalk.start).state
        #expect(state.nextStepIndex == 1)
        #expect(abs(state.distanceToNextStep - 26.16) < 0.01)
        #expect(state.distanceRemaining == route.totalDistance)
        #expect(!state.isOffRoute)
    }

    // Worked out by hand from the rules, for fixes every 1.4 m: steps 1 to 8 are at 26.16, 45.08, 56.31, 127.69,
    // 393.38, 447.10, 501.16 and 572.62 m.
    // - Step 1's prepare is covered by the start text, and step 0 is multi-cue anyway. Now at 18.2 m (d 7.96).
    // - A step passes on the second fix in a row at least 5 m past it. Step 1 passes at 33.6 m (32.2 m was the first
    //   past 31.16). Step 2's leg is 18.9 m, so its only prepare is the short-leg one on first sight, d 11.48. Now at
    //   37.8 m (d 7.28).
    // - Step 3 is "Continue." after multi-cue step 2: no prepare, no now. Passed at 63.0 m without a confirmation.
    // - Step 4: prepare at 88.2 m (d 39.49), now at 120.4 m (d 7.29), passed at 133.0 m.
    // - Step 5 is "Continue on the walkway.": no prepare, but step 4 isn't multi-cue, so now at 386.4 m (d 6.98).
    // - Steps 6 and 7: prepare at 407.4 m (d 39.70) and 462.0 m (d 39.16), now at 439.6 m and 494.2 m.
    // - Arrive: prepare at 533.4 m (d 39.22), arrived at 562.8 m, 9.82 m from the end.
    @Test
    func fixtureWalkGivesTheHandDerivedCues() throws {
        let route = try fixtureRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: route.totalDistance)))
        #expect(walk.logged == [
            Logged(13, .now(step: 1)),
            Logged(24, .prepare(step: 2, distance: 11.5)),
            Logged(27, .now(step: 2)),
            Logged(63, .prepare(step: 4, distance: 39.5)),
            Logged(86, .now(step: 4)),
            Logged(276, .now(step: 5)),
            Logged(291, .prepare(step: 6, distance: 39.7)),
            Logged(314, .now(step: 6)),
            Logged(330, .prepare(step: 7, distance: 39.2)),
            Logged(353, .now(step: 7)),
            Logged(381, .prepare(step: 8, distance: 39.2)),
            Logged(402, .arrived),
        ])
    }

    @Test
    func progressNeverGoesBack() throws {
        let route = try fixtureRoute()
        var walk = Walk(route)
        walk.feed(noisyFixtureWalk(route), accuracy: 10)
        for (previous, current) in zip(walk.states, walk.states.dropFirst()) {
            #expect(current.distanceRemaining <= previous.distanceRemaining)
            #expect(current.nextStepIndex >= previous.nextStepIndex)
        }
    }

    @Test
    func noiseKeepsTheSameCues() throws {
        let route = try fixtureRoute()
        var clean = Walk(route)
        clean.feed(onRoute(TripWalk.distances(from: 0, to: route.totalDistance)))
        var noisy = Walk(route)
        noisy.feed(noisyFixtureWalk(route), accuracy: 10)
        #expect(cueKinds(noisy.logged) == cueKinds(clean.logged))
        #expect(noisy.states.allSatisfy { !$0.isOffRoute })
    }

    @Test
    func overshootingATurnIsAMissedTurn() throws {
        let route = try fixtureRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: route.cumulativeDistances[32])))
        let start = walk.fixCount
        // step 6 turns right at vertex 32; keep walking straight on for 21 m
        let vertex = route.coordinates[32]
        let heading = GeoMath.bearing(from: route.coordinates[31], to: vertex)
        let overshoot = (1...15).map {
            TripWalk.destination(from: vertex, bearing: heading, distance: 1.4 * Double($0))
        }
        walk.feed(TripWalk.fixes(at: overshoot, start: walk.nextTime))

        // 15 m beyond first at 15.4 m, confirmed 2 s later at 18.2 m
        #expect(Array(walk.logged.drop { $0.fix < start }) == [
            Logged(start + 12, .missedTurn(step: 6, distanceBack: 18.2)),
        ])
        #expect(walk.states.last?.nextStepIndex == 6)
    }

    @Test
    func outlierAlongTheRouteIsIgnored() throws {
        let route = try fixtureRoute()
        let path = onRoute(TripWalk.distances(from: 0, to: route.totalDistance))
        var clean = Walk(route)
        clean.feed(path)
        var jumpy = path
        // 84 m to 144 m, past step 4 at 127.7 m
        jumpy[60].along += 60
        var walk = Walk(route)
        walk.feed(jumpy)
        #expect(walk.states[60] == walk.states[59])
        #expect(walk.logged == clean.logged)
    }

    @Test
    func offRouteNeedsTenSecondsOfMovement() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        let start = walk.fixCount
        walk.feed((1...40).map { (along: 99.4, lateral: -min(1.4 * Double($0), 40)) })

        // past 30 m first at 30.8 m (detour fix 22), so 10 s later at fix 32, 9.2 m on
        #expect(Array(walk.logged.drop { $0.fix < start }) == [Logged(start + 31, .offRoute)])
        #expect(!walk.states[start + 30].isOffRoute)
        #expect(walk.states[start + 31].isOffRoute)
    }

    @Test
    func standingStillWithDriftStaysOnRoute() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        var generator = SeededGenerator(seed: 7)
        walk.feed((0..<60).map { _ in
            (along: 99.4 + 2 * Double.random(in: -1...1, using: &generator),
             lateral: -35 + 2 * Double.random(in: -1...1, using: &generator))
        })
        #expect(!walk.logged.contains { $0.event == .offRoute })
        #expect(walk.states.allSatisfy { !$0.isOffRoute })
    }

    @Test
    func rejoiningBehindProgressRearmsCues() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        // the turn at 300 m gets its prepare and now cues
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 296)))
        let progressBefore = try #require(walk.states.last).distanceRemaining
        // out 40 m to the left, back 50.4 m beside the route, and in again
        walk.feed((1...29).map { (along: 295.4, lateral: -min(1.4 * Double($0), 40)) })
        walk.feed((1...36).map { (along: 295.4 - 1.4 * Double($0), lateral: -40) })
        let rejoinStart = walk.fixCount
        walk.feed((1...29).map { (along: 245.0, lateral: -40 + min(1.4 * Double($0), 40)) })
        walk.feed(onRoute(TripWalk.distances(from: 246.4, to: 300)))

        #expect(cueKinds(walk.logged) == [
            .prepare(step: 1, distance: 0), .now(step: 1), .offRoute, .backOnRoute,
            .prepare(step: 1, distance: 0), .now(step: 1),
        ])
        // within 15 m first at 14.8 m, confirmed 2 s later
        #expect(walk.logged.contains(Logged(rejoinStart + 19, .backOnRoute)))
        let afterRejoin = walk.states[rejoinStart + 19]
        #expect(!afterRejoin.isOffRoute)
        #expect(abs(afterRejoin.distanceRemaining - (route.totalDistance - 245)) < 0.01)
        #expect(afterRejoin.distanceRemaining - progressBefore > 50)
    }

    @Test
    func stepStaysNextUntilFiveMetresPast() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 300)))
        walk.feed(onRoute([302, 303]))
        #expect(walk.states.last?.nextStepIndex == 1)
        // two fixes in a row past 305 m
        walk.feed(onRoute([305.5]))
        #expect(walk.states.last?.nextStepIndex == 1)
        walk.feed(onRoute([306.5]))
        #expect(walk.states.last?.nextStepIndex == 2)
    }

    // A fix every 21 m, at 0, 21, 42, ... m. A step passes on the second fix in a row at least 5 m past it.
    // - Step 1: now at 21 m (d 5.16). It passes only at 63 m, but step 2 is the first step not yet cued, so its now
    //   comes at 42 m (d 3.08).
    // - Steps 2 and 3 pass together at 84 m. Step 2 had its now and step 3 needs none, so no confirmation.
    // - Step 4: prepare at 105 m (d 22.69), now at 126 m (d 1.69), passed at 168 m.
    // - Step 5 is at most 15.38 m away at 378 m and passed at 420 m without its now. Step 6's prepare in the same fix
    //   (d 27.10) already says what's next, so there is no confirmation. Now at 441 m (d 6.10), passed at 483 m.
    // - Step 7: prepare on first sight at 483 m (d 18.16). 504 m is already past it, so no now; passed at 546 m, where
    //   the arrive prepare (d 26.62) again replaces the confirmation. Arrived at 567 m.
    @Test
    func sparseFixesConfirmInsteadOfLateTurns() throws {
        let route = try fixtureRoute()
        var walk = Walk(route)
        let distances = TripWalk.distances(from: 0, to: route.totalDistance, interval: 15)
        walk.feed(TripWalk.fixes(on: route, path: onRoute(distances), interval: 15))
        #expect(walk.logged == [
            Logged(1, .now(step: 1)),
            Logged(2, .now(step: 2)),
            Logged(5, .prepare(step: 4, distance: 22.7)),
            Logged(6, .now(step: 4)),
            Logged(20, .prepare(step: 6, distance: 27.1)),
            Logged(21, .now(step: 6)),
            Logged(23, .prepare(step: 7, distance: 18.2)),
            Logged(26, .prepare(step: 8, distance: 26.6)),
            Logged(27, .arrived),
        ])
    }

    @Test
    func severalStepsPassedInOneFixGetOneConfirmation() throws {
        let route = try syntheticRoute([
            (0, 100, .depart, "Walk north."), (90, 10, .turnRight, "Turn right."), (0, 100, .turnLeft, "Turn left."),
        ])
        var walk = Walk(route)
        // 91 m is still 9 m short of the first turn; 121 m and 151 m are past both
        walk.feed(TripWalk.fixes(on: route, path: onRoute([0, 30, 61, 91, 121, 151]), interval: 15))
        #expect(walk.logged == [
            Logged(2, .prepare(step: 1, distance: 39)),
            Logged(5, .passedTurnConfirmation(step: 2)),
        ])
        #expect(walk.states.last?.nextStepIndex == 3)
    }

    @Test
    func outAndBackArrivesOnlyAtTheEnd() throws {
        let route = try syntheticRoute([(0, 100, .depart, "Walk north."), (180, 100, .uTurn, "Turn around.")])
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 200)))
        // remaining reaches 10 m at 190.4 m, on the way back past the start of the first leg
        #expect(walk.logged == [
            Logged(43, .prepare(step: 1, distance: 39.8)),
            Logged(66, .now(step: 1)),
            Logged(115, .prepare(step: 2, distance: 39)),
            Logged(136, .arrived),
        ])
    }

    @Test
    func ignoresStaleOutOfOrderAndInvalidFixes() throws {
        let route = try fixtureRoute()
        var tracker = RouteProgressTracker(route: route, startedAt: TripWalk.start)
        func fix(_ along: Double, at seconds: TimeInterval, accuracy: Double = 5) -> LocationSample {
            LocationSample(coordinate: TripWalk.point(on: route, along: along), horizontalAccuracy: accuracy,
                           timestamp: TripWalk.start.addingTimeInterval(seconds))
        }
        let initial = tracker.state

        #expect(tracker.update(with: fix(4, at: -10)) == .init(state: initial, events: []))
        #expect(tracker.update(with: fix(0, at: 0)).state == initial)
        #expect(tracker.update(with: fix(4, at: -1)).state == initial)
        #expect(tracker.update(with: fix(4, at: 0)).state == initial)
        let invalid = LocationSample(coordinate: GeoCoordinate(latitude: .nan, longitude: -84.399),
                                     horizontalAccuracy: 5, timestamp: TripWalk.start.addingTimeInterval(5))
        #expect(tracker.update(with: invalid) == .init(state: initial, events: []))
        #expect(tracker.update(with: fix(4, at: 1, accuracy: .nan)).state == initial)
        #expect(tracker.update(with: fix(4, at: 1, accuracy: 40)).state == initial)

        // the invalid fix at 5 s didn't block a valid one at 2 s
        let moved = tracker.update(with: fix(2.8, at: 2)).state
        #expect(abs(moved.distanceRemaining - (route.totalDistance - 2.8)) < 0.01)
    }

    @Test
    func walkingTheWrongWayWarnsOnce() throws {
        let route = try fixtureRoute()
        var walk = Walk(route)
        // the route starts south; walk 15.4 m north
        walk.feed((0...11).map { (along: -1.4 * Double($0), lateral: 0) })
        #expect(walk.logged == [Logged(8, .wrongWay)])
    }

    @Test
    func pausedCuesFireOnResume() throws {
        let route = try fixtureRoute()
        var walk = Walk(route)
        let fixes = TripWalk.fixes(on: route, path: onRoute(TripWalk.distances(from: 0, to: 42)))
        walk.feed(Array(fixes[..<10]))
        // step 1's now falls due at fix 13, while paused
        walk.feed(Array(fixes[10..<14]), emitsCues: false)
        walk.feed(Array(fixes[14...]))
        #expect(walk.logged == [
            Logged(14, .now(step: 1)),
            Logged(24, .prepare(step: 2, distance: 11.5)),
            Logged(27, .now(step: 2)),
        ])
    }

    @Test
    func arrivesWhilePaused() throws {
        let route = try fixtureRoute()
        var walk = Walk(route)
        let fixes = TripWalk.fixes(on: route, path: onRoute(TripWalk.distances(from: 0, to: route.totalDistance)))
        walk.feed(Array(fixes[..<395]))
        walk.feed(Array(fixes[395...]), emitsCues: false)
        #expect(walk.logged.last == Logged(402, .arrived))
        #expect(walk.logged.filter { $0.event == .arrived }.count == 1)
    }

    @Test
    func turnJustBeforeTheEndStillArrives() throws {
        let route = try syntheticRoute([(0, 100, .depart, "Walk north."), (90, 3, .turnRight, "Turn right.")])
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: route.totalDistance)))
        // the turn can't be passed by 5 m, but 93.8 m is within 10 m of the end
        #expect(walk.logged == [
            Logged(43, .prepare(step: 1, distance: 39.8)),
            Logged(66, .now(step: 1)),
            Logged(67, .arrived),
        ])
        #expect(walk.states.last?.nextStepIndex == 2)
    }

    @Test
    func dropoutAtTheTurnaroundStillFollowsTheReturnLeg() throws {
        let route = try syntheticRoute([(0, 100, .depart, "Walk north."), (180, 100, .uTurn, "Turn around.")])
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        // nothing for 5 s after 99.4 m, then 6.6 m back down the return leg
        let back = onRoute(TripWalk.distances(from: 106.6, to: 200))
        walk.feed(TripWalk.fixes(on: route, path: back, start: TripWalk.start.addingTimeInterval(77)))
        #expect(walk.logged.last?.event == .arrived)
        #expect(walk.logged.filter { $0.event == .arrived }.count == 1)
    }

    @Test
    func coarseFixesNeverRejoin() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        walk.feed((1...40).map { (along: 99.4, lateral: -min(1.4 * Double($0), 40)) })
        let offRoute = try #require(walk.states.last)
        #expect(offRoute.isOffRoute)
        walk.feed(onRoute([200, 200, 200]), accuracy: 200)
        #expect(walk.states.last == offRoute)
        #expect(!walk.logged.contains { $0.event == .backOnRoute })
    }

    @Test
    func imprecisePositionAtTheStartIsNotTheWrongWay() throws {
        let route = try fixtureRoute()
        var walk = Walk(route)
        // a cold first fix 15 m off, then precise fixes walking the route
        walk.feed([(along: 0, lateral: 15)], accuracy: 20)
        walk.feed(onRoute(TripWalk.distances(from: 1.4, to: 50)))
        #expect(!walk.logged.contains { $0.event == .wrongWay })
    }

    @Test
    func walkingToTheRouteStartIsNotTheWrongWay() throws {
        let route = try fixtureRoute()
        var walk = Walk(route)
        // 12 m short of the start, walking onto the route
        walk.feed(onRoute(TripWalk.distances(from: -12, to: 30)))
        #expect(!walk.logged.contains { $0.event == .wrongWay })
    }

    @Test
    func walkingStraightPastASixtyDegreeTurnIsAMissedTurn() throws {
        // 61°, since a 60° route's turn measures a hair either side of the 60° threshold
        let route = try turnRoute(61)
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        let start = walk.fixCount
        walk.feed(straightOn(past: route, count: 18, start: walk.nextTime))
        // 15 m from the outgoing leg (d sin 61°) first at 18.2 m, confirmed 2 s later at 21.0 m
        #expect(Array(walk.logged.drop { $0.fix < start }) == [
            Logged(start + 14, .missedTurn(step: 1, distanceBack: 21)),
        ])
        #expect(walk.states.last?.nextStepIndex == 1)
    }

    @Test
    func noisyOvershootOfARightAngleTurnIsMissedWithinTwentyMetres() throws {
        let route = try turnRoute(90)
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        var generator = SeededGenerator(seed: 11)
        walk.feed(straightOn(past: route, count: 20, start: walk.nextTime) { _ in
            (3 * Double.random(in: -1...1, using: &generator), 3 * Double.random(in: -1...1, using: &generator))
        })
        let missed = walk.logged.compactMap { logged -> Double? in
            guard case let .missedTurn(step: 1, distanceBack: distance) = logged.event else { return nil }
            return distance
        }
        #expect(missed.count == 1)
        #expect(try #require(missed.first) <= 21)
    }

    @Test(arguments: [61.0, 90])
    func walkingThroughANoisyTurnNeverMissesIt(_ bearing: Double) throws {
        let route = try turnRoute(bearing)
        var walk = Walk(route)
        var generator = SeededGenerator(seed: 5)
        walk.feed(TripWalk.distances(from: 0, to: route.totalDistance).map { along in
            (along + 3 * Double.random(in: -1...1, using: &generator), 3 * Double.random(in: -1...1, using: &generator))
        })
        #expect(cueKinds(walk.logged) == [
            .prepare(step: 1, distance: 0), .now(step: 1), .prepare(step: 2, distance: 0), .arrived,
        ])
    }

    @Test
    func stepsSharingAVertexEachGetTheirCue() throws {
        let corner = TripWalk.destination(from: GeoCoordinate(latitude: 33.775, longitude: -84.399), bearing: 0,
                                          distance: 100)
        let coordinates = [GeoCoordinate(latitude: 33.775, longitude: -84.399), corner,
                           TripWalk.destination(from: corner, bearing: 90, distance: 100)]
        func step(_ kind: ManeuverKind, at index: Int, _ text: String) -> RouteStep {
            RouteStep(kind: kind, coordinateIndex: index, instruction: text, spokenInstruction: text)
        }
        let route = try NavigationRoute(coordinates: coordinates, steps: [
            step(.depart, at: 0, "Walk north."), step(.turnRight, at: 1, "Turn right."),
            step(.slightLeft, at: 1, "Bear left."), step(.arrive, at: 2, "You have arrived."),
        ], estimatedDuration: 0)
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: route.totalDistance)))
        #expect(walk.logged == [
            Logged(43, .prepare(step: 1, distance: 39.8)),
            Logged(66, .now(step: 1)),
            Logged(66, .now(step: 2)),
            Logged(115, .prepare(step: 3, distance: 39)),
            Logged(136, .arrived),
        ])
    }

    // from a live route: a multi-cue "Continue…" step 1 m before a left turn, then a turn 30 m on
    @Test
    func turnAMetreAfterAMultiCueContinueIsCoveredByIt() throws {
        let start = GeoCoordinate(latitude: 33.775, longitude: -84.399)
        let continueAt = TripWalk.destination(from: start, bearing: 0, distance: 100)
        let leftAt = TripWalk.destination(from: continueAt, bearing: 0, distance: 1)
        let rightAt = TripWalk.destination(from: leftAt, bearing: 270, distance: 30)
        let end = TripWalk.destination(from: rightAt, bearing: 0, distance: 50)
        func step(_ kind: ManeuverKind, at index: Int, _ text: String, multiCue: Bool = false) -> RouteStep {
            RouteStep(kind: kind, coordinateIndex: index, instruction: text, spokenInstruction: text,
                      announcesNextStep: multiCue)
        }
        let route = try NavigationRoute(coordinates: [start, continueAt, leftAt, rightAt, end], steps: [
            step(.depart, at: 0, "Walk north."),
            step(.straight, at: 1, "Continue on the walkway. Then Turn left onto the walkway.", multiCue: true),
            step(.turnLeft, at: 2, "Turn left onto the walkway."),
            step(.turnRight, at: 3, "Turn right onto the path."),
            step(.arrive, at: 4, "You have arrived."),
        ], estimatedDuration: 0)
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: route.totalDistance)))

        // step 1 says "Continue", so it has no prepare; its own sentence names the turn 1 m on, so that gets no
        // separate cue and no confirmation
        #expect(cueKinds(walk.logged) == [
            .now(step: 1), .prepare(step: 3, distance: 0), .now(step: 3), .prepare(step: 4, distance: 0), .arrived,
        ])
    }

    @Test
    func preciseFixAtTheEndArrivesWhenProgressCantJumpThere() throws {
        let route = try syntheticRoute([(0, 100, .depart, "Walk north.")])
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 59)))
        // 41.2 m in 1 s is past the speed cap, so only the raw distance to the end can arrive
        walk.feed(onRoute([100]))
        #expect(walk.logged == [Logged(43, .arrived)])
    }

    @Test
    func twoPointRouteGuidesToTheEnd() throws {
        let route = try syntheticRoute([(0, 100, .depart, "Walk north.")])
        var walk = Walk(route)
        #expect(walk.tracker.state.nextStepIndex == 1)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        #expect(walk.logged == [Logged(43, .prepare(step: 1, distance: 39.8)), Logged(65, .arrived)])
    }

    @Test
    func routeShorterThanAPrepareOnlyArrives() throws {
        let route = try syntheticRoute([(0, 30, .depart, "Walk north.")])
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 30)))
        // the start announcement already covers the arrival, so no prepare
        #expect(walk.logged == [Logged(15, .arrived)])
    }

    @Test
    func offRouteIsReportedWhilePaused() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        let start = walk.fixCount
        walk.feed((1...40).map { (along: 99.4, lateral: -min(1.4 * Double($0), 40)) }, emitsCues: false)
        #expect(Array(walk.logged.drop { $0.fix < start }) == [Logged(start + 31, .offRoute)])
    }

    // a steady sideways GPS bias puts a correct walker nearer the straight-on line than the route for a while
    @Test(arguments: [(45.0, -8.0), (30, -10), (61, -10)])
    func steadySidewaysBiasThroughATurnIsNotAMissedTurn(_ bearing: Double, _ bias: Double) throws {
        let route = try turnRoute(bearing)
        var walk = Walk(route)
        var generator = SeededGenerator(seed: 3)
        walk.feed(TripWalk.distances(from: 0, to: route.totalDistance).map { along in
            (along + 3 * Double.random(in: -1...1, using: &generator),
             bias + 3 * Double.random(in: -1...1, using: &generator))
        })
        #expect(!walk.logged.contains { if case .missedTurn = $0.event { true } else { false } })
        #expect(walk.states.contains { $0.nextStepIndex == 2 })
        #expect(walk.logged.last?.event == .arrived)
    }

    @Test
    func roughFixAtTheStartIsNotTheWrongWay() throws {
        let route = try fixtureRoute()
        var walk = Walk(route)
        walk.feed([(along: 0, lateral: 0)])
        // 12 m to the side, but only accurate to 25 m
        walk.feed([(along: 0, lateral: 12)], accuracy: 25)
        #expect(walk.logged.isEmpty)
    }

    @Test(arguments: 1...20)
    func standingStillOnAnOutAndBackLegNeverJumpsToTheReturn(_ seed: UInt64) throws {
        let route = try syntheticRoute([(0, 100, .depart, "Walk north."), (180, 100, .uTurn, "Turn around.")])
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 50)))
        var generator = SeededGenerator(seed: seed)
        // a minute of waiting at 49 m with GPS noise, half of it behind progress
        walk.feed((0..<60).map { _ in
            (49 + 5 * Double.random(in: -1...1, using: &generator), 3 * Double.random(in: -1...1, using: &generator))
        })
        #expect(walk.states.allSatisfy { $0.distanceRemaining > 140 })
    }

    /// North 100 m to the first step, then `legs` (west unless given), each starting a step, then an arrival.
    private func closeStepsRoute(_ legs: [(length: Double, bearing: Double, kind: ManeuverKind, text: String,
                                           multiCue: Bool)]) throws -> NavigationRoute {
        var coordinates = [GeoCoordinate(latitude: 33.775, longitude: -84.399)]
        coordinates.append(TripWalk.destination(from: coordinates[0], bearing: 0, distance: 100))
        var steps = [RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Walk north.",
                               spokenInstruction: "Walk north.")]
        for leg in legs {
            steps.append(RouteStep(kind: leg.kind, coordinateIndex: coordinates.count - 1, instruction: leg.text,
                                   spokenInstruction: leg.text, announcesNextStep: leg.multiCue))
            coordinates.append(TripWalk.destination(from: coordinates[coordinates.count - 1], bearing: leg.bearing,
                                                    distance: leg.length))
        }
        steps.append(RouteStep(kind: .arrive, coordinateIndex: coordinates.count - 1, instruction: "Arrive",
                               spokenInstruction: "You have arrived."))
        return try NavigationRoute(coordinates: coordinates, steps: steps, estimatedDuration: 0)
    }

    private func walkAtTwoMetresASecond(_ route: NavigationRoute) -> Walk {
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: route.totalDistance, speed: 2)))
        return walk
    }

    // from a live route: at 2 m/s a multi-cue turn is only passed after the stairs 6 m on
    @Test
    func stepSixMetresAfterAMultiCueTurnIsCoveredByIt() throws {
        let route = try closeStepsRoute([
            (6, 270, .turnLeft, "Turn left onto the walkway. Then Take the stairs.", true),
            (40, 270, .straight, "Take the stairs.", false),
        ])
        let walk = walkAtTwoMetresASecond(route)
        #expect(cueKinds(walk.logged) == [
            .prepare(step: 1, distance: 0), .now(step: 1), .prepare(step: 3, distance: 0), .arrived,
        ])
    }

    @Test
    func stepsSixMetresApartAreBothCuedTogether() throws {
        let route = try closeStepsRoute([
            (6, 270, .turnLeft, "Turn left onto the walkway.", false),
            (40, 270, .straight, "Take the stairs.", false),
        ])
        let walk = walkAtTwoMetresASecond(route)
        #expect(cueKinds(walk.logged) == [
            .prepare(step: 1, distance: 0), .now(step: 1), .now(step: 2), .prepare(step: 3, distance: 0), .arrived,
        ])
        let fixes = walk.logged.filter { $0.event == .now(step: 1) || $0.event == .now(step: 2) }.map(\.fix)
        #expect(fixes.count == 2 && fixes[0] == fixes[1])
    }

    @Test
    func chainOfStepsFourMetresApartIsCuedTogether() throws {
        let route = try closeStepsRoute([
            (4, 270, .turnLeft, "Turn left.", false),
            (4, 0, .turnRight, "Turn right.", false),
            (40, 270, .turnLeft, "Turn left again.", false),
        ])
        let walk = walkAtTwoMetresASecond(route)
        #expect(cueKinds(walk.logged) == [
            .prepare(step: 1, distance: 0), .now(step: 1), .now(step: 2), .now(step: 3),
            .prepare(step: 4, distance: 0), .arrived,
        ])
        let fixes = Set(walk.logged.filter { if case .now = $0.event { true } else { false } }.map(\.fix))
        #expect(fixes.count == 1)
    }

    @Test
    func longRunOfCloseStepsIsCuedAFewAtATime() throws {
        // seven steps 7 m apart, from 100 m to 142 m
        let route = try closeStepsRoute((1...7).map { index in
            (length: index == 7 ? 40.0 : 7.0, bearing: index.isMultiple(of: 2) ? 0.0 : 270.0,
             kind: index.isMultiple(of: 2) ? ManeuverKind.turnRight : .turnLeft, text: "Turn \(index).", multiCue: false)
        })
        let walk = walkAtTwoMetresASecond(route)
        let nows = walk.logged.compactMap { logged -> (fix: Int, step: Int)? in
            guard case let .now(step) = logged.event else { return nil }
            return (logged.fix, step)
        }
        // groups reach 16 m from their first step: steps 1 to 3, 4 to 6, then 7 on its own
        #expect(nows.map(\.step) == Array(1...7))
        #expect(Dictionary(grouping: nows, by: \.fix).values.map(\.count).sorted() == [1, 3, 3])
        #expect(!walk.logged.contains { if case .passedTurnConfirmation = $0.event { true } else { false } })
    }
}
