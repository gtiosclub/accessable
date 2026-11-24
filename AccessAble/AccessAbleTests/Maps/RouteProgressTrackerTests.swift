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

/// The fixes with a walking `speed` and `course`, as Core Location gives them while walking that way.
private func walking(_ fixes: [LocationSample], course: Double?, speed: Double? = 1.4) -> [LocationSample] {
    fixes.map { fix in
        var fix = fix
        fix.speed = speed
        fix.course = course
        return fix
    }
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

    init(_ route: NavigationRoute, crossings: [Double] = []) {
        tracker = RouteProgressTracker(route: route, startedAt: TripWalk.start, crossings: crossings)
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

/// The fixes, each marked as coming from `source(index)`.
private func sourced(_ fixes: [LocationSample], _ source: (Int) -> LocationSource) -> [LocationSample] {
    fixes.enumerated().map { index, fix in
        var fix = fix
        fix.source = source(index)
        return fix
    }
}

/// Whether the event says the user moved: off route, the wrong way or past a turn.
private func isMovement(_ logged: Logged) -> Bool {
    switch logged.event {
    case .offRoute, .wrongWay, .missedTurn: true
    default: false
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
    func walkingAwayFromTheRouteIsOffRouteWithinSixSeconds() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        let start = walk.fixCount
        let detour = (1...40).map { (along: 99.4, lateral: -min(1.4 * Double($0), 40)) }
        walk.feed(walking(TripWalk.fixes(on: route, path: detour, start: walk.nextTime), course: 270))

        // past 20 m first at 21 m (detour fix 15), so 5 s later at fix 20, long before the 30 m rule's fix 32
        let firstPast = start + 14
        #expect(Array(walk.logged.drop { $0.fix < start }) == [Logged(firstPast + 5, .offRoute)])
        #expect(walk.states[..<(firstPast + 5)].allSatisfy { !$0.isOffRoute })
    }

    // GPS and AR place someone standing still apart; the step between them when the source switches isn't movement
    @Test
    func switchingSourceAtTheStartIsNotTheWrongWay() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        // AR puts the user 20 m west of GPS, and the source switches every 3 s
        let isGPS = { (index: Int) in (index / 3).isMultiple(of: 2) }
        let path = (0..<60).map { (along: 0.0, lateral: isGPS($0) ? 0.0 : -20) }
        walk.feed(sourced(TripWalk.fixes(on: route, path: path, start: walk.nextTime)) { isGPS($0) ? .gps : .ar })

        #expect(!walk.logged.contains(where: isMovement))
    }

    @Test
    func switchingSourceFarFromTheRouteIsNotLeavingIt() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        // standing 32 m off, where AR puts the user 23 m further
        let path = (0..<30).map { (along: 99.4, lateral: (5..<25).contains($0) ? -55.0 : -32) }
        walk.feed(sourced(TripWalk.fixes(on: route, path: path, start: walk.nextTime)) {
            (5..<25).contains($0) ? .ar : .gps
        })

        #expect(!walk.logged.contains(where: isMovement))
        #expect(walk.states.allSatisfy { !$0.isOffRoute })
    }

    @Test
    func switchingSourceAtATurnIsNotMissingIt() throws {
        let route = try turnRoute(90)
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 99)))
        // just before the turn, where AR puts the user 20 m straight on past it; the source switches every fix
        let ahead = TripWalk.destination(from: route.coordinates[1], bearing: 0, distance: 20)
        let coordinates = (0..<30).map { $0.isMultiple(of: 2) ? TripWalk.point(on: route, along: 99) : ahead }
        walk.feed(sourced(TripWalk.fixes(at: coordinates, start: walk.nextTime)) { $0.isMultiple(of: 2) ? .gps : .ar })

        #expect(!walk.logged.contains(where: isMovement))
    }

    @Test
    func walkingOffWhileTheSourceKeepsSwitchingIsStillOffRoute() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        let start = walk.fixCount
        // AR puts the user 20 m further out than GPS, and the source switches every 3 s
        let isGPS = { (index: Int) in (index / 3).isMultiple(of: 2) }
        let detour = (0..<40).map { index in
            (along: 99.4, lateral: -1.4 * Double(index + 1) - (isGPS(index) ? 0 : 20))
        }
        walk.feed(sourced(TripWalk.fixes(on: route, path: detour, start: walk.nextTime)) { isGPS($0) ? .gps : .ar })

        // both sources are past 30 m from detour fix 22, and 10 s and 9.8 m of walking later the run is complete;
        // on GPS alone it is off route on the same fix
        #expect(Array(walk.logged.drop { $0.fix < start }) == [Logged(start + 31, .offRoute)])
    }

    @Test
    func comingBackWhileTheSourceKeepsSwitchingIsBackOnRoute() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        walk.feed((1...40).map { (along: 99.4, lateral: -min(1.4 * Double($0), 40)) })
        #expect(walk.states.last?.isOffRoute == true)
        let start = walk.fixCount
        // AR puts the user 10 m further out than GPS, and the source switches every 2 fixes, faster than the 2 s a
        // rejoin takes
        let isGPS = { (index: Int) in (index / 2).isMultiple(of: 2) }
        let back = (0..<40).map { index in
            (along: 99.4, lateral: -max(40 - 1.4 * Double(index), 0) - (isGPS(index) ? 0 : 10))
        }
        walk.feed(sourced(TripWalk.fixes(on: route, path: back, start: walk.nextTime)) { isGPS($0) ? .gps : .ar })

        // every fix is within 15 m from fix 24, so back on route 2 s later
        #expect(Array(walk.logged.drop { $0.fix < start }) == [Logged(start + 26, .backOnRoute)])
    }

    // fusion switches within 4 s of the last fix it passed on, so a longer gap holds walking and the runs start over
    @Test(arguments: zip([4.0, 4.1], [4, 10]))
    func aSwitchShiftsTheRunsUpToFourSecondsAfterTheLastFix(gap: TimeInterval, firesAfter: Int) throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        // walking off on GPS, past 30 m from detour fix 22, then nothing for `gap`, then AR 20 m further out
        walk.feed((1...24).map { (along: 99.4, lateral: -1.4 * Double($0)) })
        let arStart = walk.fixCount
        let resumed = walk.nextTime.addingTimeInterval(gap - 1)
        let path = (0..<12).map { (along: 99.4, lateral: -1.4 * (24 + gap + Double($0)) - 20) }
        walk.feed(sourced(TripWalk.fixes(on: route, path: path, start: resumed)) { _ in .ar })

        // shifted, the GPS run goes on and has 8.4 m of walking 4 fixes later; restarted, it needs 10 s from the
        // first AR fix
        #expect(Array(walk.logged.drop { $0.fix < arStart }) == [Logged(arStart + firesAfter, .offRoute)])
    }

    @Test
    func aShortFixForgivenOnOneSourceCantBeConfirmedByTheOther() throws {
        let route = try turnRoute(61)
        let vertex = route.coordinates[1]
        let past = { (distance: Double) in TripWalk.destination(from: vertex, bearing: 0, distance: distance) }
        // past the turn, short of it, then past it again 2 s after the first
        let fixes = TripWalk.fixes(at: [past(21), TripWalk.point(on: route, along: 99), past(22)],
                                   start: TripWalk.start.addingTimeInterval(80))

        var gpsOnly = Walk(route)
        gpsOnly.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        let start = gpsOnly.fixCount
        gpsOnly.feed(fixes)
        #expect(gpsOnly.logged.drop { $0.fix < start }.map(\.fix) == [start + 2])

        var switching = Walk(route)
        switching.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        switching.feed(sourced(fixes) { $0 == 2 ? .ar : .gps })
        #expect(!switching.logged.contains(where: isMovement))
    }

    @Test
    func walkingOffAfterAGapAndASwitchStartsTheRunsOver() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        let start = walk.fixCount
        // walking off on GPS, nothing for 8 s, then AR, which puts the user 20 m further out
        let path = (1...50).map { (along: 99.4, lateral: -1.4 * Double($0) - ($0 > 32 ? 20 : 0)) }
        let fixes = sourced(TripWalk.fixes(on: route, path: path, start: walk.nextTime)) { $0 >= 32 ? .ar : .gps }
        walk.feed(Array(fixes[..<24]) + Array(fixes[32...]))

        // the step after the gap holds walking as well as the sources' difference, so the run starts over at the
        // first AR fix and is complete 10 s and 14 m later
        #expect(Array(walk.logged.drop { $0.fix < start }) == [Logged(start + 34, .offRoute)])
    }

    @Test
    func walkingPastATurnWhileTheSourceKeepsSwitchingIsAMissedTurn() throws {
        let route = try turnRoute(61)
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        let start = walk.fixCount
        // AR puts the user 3 m further on than GPS, and the source switches every 2 fixes
        let isGPS = { (index: Int) in (index / 2).isMultiple(of: 2) }
        let fixes = straightOn(past: route, count: 18, start: walk.nextTime) { isGPS($0 - 1) ? (0, 0) : (3, 0) }
        walk.feed(sourced(fixes) { isGPS($0) ? .gps : .ar })

        // AR is 15 m from the outgoing leg first at fix 11, and GPS confirms it 2 s later; on GPS alone that comes
        // at fix 15
        #expect(Array(walk.logged.drop { $0.fix < start }) == [
            Logged(start + 12, .missedTurn(step: 1, distanceBack: 18.2)),
        ])
    }

    @Test
    func walkingAwayRightAfterSwitchingSourceIsStillOffRoute() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        let start = walk.fixCount
        let detour = (1...40).map { (along: 99.4, lateral: -min(1.4 * Double($0), 40)) }
        let fixes = walking(TripWalk.fixes(on: route, path: detour, start: walk.nextTime), course: 270)
        walk.feed(sourced(fixes) { _ in .ar })

        // as on GPS alone: past 20 m first at detour fix 15, and off route 5 s later
        #expect(Array(walk.logged.drop { $0.fix < start }) == [Logged(start + 19, .offRoute)])
    }

    // a gap in fixes mustn't let two of them alone decide it
    @Test
    func walkingAwayNeedsThreeFixesHoweverFarApart() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        let start = walk.fixCount
        let detour = (1...40).map { (along: 99.4, lateral: -min(1.4 * Double($0), 40)) }
        let fixes = walking(TripWalk.fixes(on: route, path: detour, start: walk.nextTime), course: 270)
        // one fix every 5 s, the first of them 21 m off
        walk.feed(stride(from: 14, to: fixes.count, by: 5).map { fixes[$0] })

        #expect(Array(walk.logged.drop { $0.fix < start }) == [Logged(start + 2, .offRoute)])
    }

    @Test
    func walkingAwayWithoutAWalkingDirectionWaitsForTheThirtyMetreRule() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        let start = walk.fixCount
        let detour = (1...40).map { (along: 99.4, lateral: -min(1.4 * Double($0), 40)) }
        walk.feed(walking(TripWalk.fixes(on: route, path: detour, start: walk.nextTime), course: nil, speed: nil))

        #expect(Array(walk.logged.drop { $0.fix < start }) == [Logged(start + 31, .offRoute)])
    }

    @Test(arguments: [nil, 0.0])
    func standingStillWithDriftAndAStaleCourseStaysOnRoute(_ speed: Double?) throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        var generator = SeededGenerator(seed: 7)
        // drifting out from 35 m to 38 m, the course pointing away: only the speed shows it isn't walking
        let drift = (0..<30).map {
            (along: 99.4 + 2 * Double.random(in: -1...1, using: &generator), lateral: -35 - 0.1 * Double($0))
        }
        walk.feed(walking(TripWalk.fixes(on: route, path: drift, start: walk.nextTime), course: 270, speed: speed))

        #expect(!walk.logged.contains { $0.event == .offRoute })
        #expect(walk.states.allSatisfy { !$0.isOffRoute })
    }

    @Test
    func walkingAlongsideTheRouteStaysOnRoute() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        let alongside = TripWalk.distances(from: 100, to: 142).map { (along: $0, lateral: -25.0) }
        walk.feed(walking(TripWalk.fixes(on: route, path: alongside, start: walk.nextTime), course: 0))

        #expect(walk.states.allSatisfy { !$0.isOffRoute })
    }

    @Test
    func walkingBackTowardTheRouteAtASteepAngleStaysOnRoute() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        // from 40 m to the left, at 1.4 m/s on a course 70° off the route's, so 1.32 m nearer each second
        let back = (0..<20).map { second -> (along: Double, lateral: Double) in
            (99.4 + 0.48 * Double(second), -40 + 1.32 * Double(second))
        }
        walk.feed(walking(TripWalk.fixes(on: route, path: back, start: walk.nextTime), course: 70))

        #expect(walk.states.allSatisfy { !$0.isOffRoute })
    }

    @Test
    func walkingAwayWithRoughFixesWaitsForTheScaledLimit() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        let start = walk.fixCount
        let detour = (1...40).map { (along: 99.4, lateral: -min(1.4 * Double($0), 40)) }
        walk.feed(walking(TripWalk.fixes(on: route, path: detour, start: walk.nextTime, accuracy: 20), course: 270))

        // 20 m accuracy scales the limit to 30 m, so 25 m off (detour fix 18) isn't enough: past 30 m first at
        // 30.8 m (detour fix 22), so 5 s later at fix 27
        #expect(Array(walk.logged.drop { $0.fix < start }) == [Logged(start + 26, .offRoute)])
        #expect(!walk.states[start + 25].isOffRoute)
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
    func offRouteOnTheSameFixReplacesTheWrongWay() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        // west from the start: rough fixes give no wrong way, until a precise one 28 m off, which also has been
        // walking away for 5 s
        let path = (0...20).map { (along: 0.0, lateral: -1.4 * Double($0)) }
        let fixes = TripWalk.fixes(on: route, path: path, start: walk.nextTime, accuracy: 12)
            .enumerated().map { index, fix in
                var fix = fix
                if index == 0 || index == 20 { fix.horizontalAccuracy = 5 }
                return fix
            }
        walk.feed(walking(fixes, course: 270))
        #expect(walk.logged == [Logged(20, .offRoute)])
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

    @Test
    func eachCrossingIsAnnouncedOnceBeforeItIsReachedOnANoisyWalk() throws {
        let route = try fixtureRoute()
        let crossings = [60.0, 250, 403.7]
        var walk = Walk(route, crossings: crossings)
        walk.feed(noisyFixtureWalk(route), accuracy: 10)

        for index in crossings.indices {
            let announced = walk.logged.filter { $0.event == .crossing(index: index) }
            #expect(announced.count == 1)
            let fix = try #require(announced.first).fix
            let walked = route.totalDistance - walk.states[fix].distanceRemaining
            #expect((0...20).contains(crossings[index] - walked))
        }
    }

    @Test
    func noCrossingIsAnnouncedWhileOffRoute() throws {
        let route = try cornerRoute()
        var walk = Walk(route, crossings: [150])
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        // out 40 m to the left, then on beside the route past the crossing
        walk.feed((1...29).map { (along: 99.4, lateral: -min(1.4 * Double($0), 40)) })
        walk.feed(TripWalk.distances(from: 100.8, to: 170).map { (along: $0, lateral: -40) })

        #expect(walk.logged.map(\.event).contains(.offRoute))
        #expect(!walk.logged.contains { if case .crossing = $0.event { true } else { false } })
    }

    @Test
    func crossingDueWhilePausedIsAnnouncedOnceCuesResume() throws {
        let route = try cornerRoute()
        var walk = Walk(route, crossings: [100])
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 70)))
        walk.feed(onRoute(TripWalk.distances(from: 71.4, to: 84)), emitsCues: false)
        #expect(walk.logged.isEmpty)
        let resumed = walk.fixCount
        walk.feed(onRoute(TripWalk.distances(from: 85.4, to: 95)))

        #expect(walk.logged == [Logged(resumed, .crossing(index: 0))])
    }

    @Test
    func crossingAlreadyBehindTheFirstFixIsNotAnnounced() throws {
        let route = try cornerRoute()
        var walk = Walk(route, crossings: [5, 30])
        // a rough first fix is let 20 m along at once
        walk.feed([(along: 15, lateral: 0)], accuracy: 20)
        walk.feed(onRoute(TripWalk.distances(from: 16.4, to: 60)))

        #expect(walk.logged == [Logged(0, .crossing(index: 1))])
    }

    @Test
    func rejoiningBehindACrossingAnnouncesItAgain() throws {
        let route = try cornerRoute()
        var walk = Walk(route, crossings: [280])
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 296)))
        // out 40 m to the left, back 50.4 m beside the route, and in again at 245 m
        walk.feed((1...29).map { (along: 295.4, lateral: -min(1.4 * Double($0), 40)) })
        walk.feed((1...36).map { (along: 295.4 - 1.4 * Double($0), lateral: -40) })
        walk.feed((1...29).map { (along: 245.0, lateral: -40 + min(1.4 * Double($0), 40)) })
        walk.feed(onRoute(TripWalk.distances(from: 246.4, to: 300)))

        let events = walk.logged.map(\.event).filter { event in
            switch event {
            case .crossing, .offRoute, .backOnRoute: true
            default: false
            }
        }
        #expect(events == [.crossing(index: 0), .offRoute, .backOnRoute, .crossing(index: 0)])
    }

    @Test
    func turnCueOnTheSameFixComesBeforeTheCrossing() throws {
        let route = try cornerRoute()
        // the turn at 300 m is prepared 40 m before, where the crossing at 280 m is 20 m ahead
        var walk = Walk(route, crossings: [280])
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 270)))

        let fix = TripWalk.distances(from: 0, to: 270).firstIndex { $0 >= 260 } ?? -1
        #expect(walk.logged == [Logged(fix, .prepare(step: 1, distance: 39.6)), Logged(fix, .crossing(index: 0))])
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

    // without the warning, at 2 m/s the turn is passed with the next step 7 m ahead, inside nowDistance
    @Test
    func stairsAfterAShortLegAreWarnedBeforeTheTurn() throws {
        func walk(_ kind: ManeuverKind) throws -> Walk {
            walkAtTwoMetresASecond(try closeStepsRoute([
                (15, 270, .turnLeft, "Turn left onto the walkway.", false),
                (40, 270, kind, "Take the stairs up.", false),
            ]))
        }
        let stairs = try walk(.stairs)
        #expect(cueKinds(stairs.logged) == [
            .prepare(step: 1, distance: 0), .prepare(step: 2, distance: 0), .now(step: 1), .now(step: 2),
            .prepare(step: 3, distance: 0), .arrived,
        ])
        let warning = try #require(stairs.logged.first { cueKinds([$0]) == [.prepare(step: 2, distance: 0)] })
        guard case let .prepare(_, distance) = warning.event else { return }
        #expect((30...40).contains(distance))
        #expect(cueKinds(try walk(.straight).logged) == [
            .prepare(step: 1, distance: 0), .now(step: 1), .now(step: 2), .prepare(step: 3, distance: 0), .arrived,
        ])
    }

    @Test
    func stairsAfterAMultiCueTurnStillGetTheirWarning() throws {
        func walk(_ kind: ManeuverKind) throws -> Walk {
            walkAtTwoMetresASecond(try closeStepsRoute([
                (30, 270, .turnLeft, "Turn left onto the walkway. Then Take the stairs.", true),
                (40, 270, kind, "Take the stairs.", false),
            ]))
        }
        #expect(cueKinds(try walk(.stairs).logged) == [
            .prepare(step: 1, distance: 0), .prepare(step: 2, distance: 0), .now(step: 1), .now(step: 2),
            .prepare(step: 3, distance: 0), .arrived,
        ])
        #expect(cueKinds(try walk(.straight).logged) == [
            .prepare(step: 1, distance: 0), .now(step: 1), .now(step: 2), .prepare(step: 3, distance: 0), .arrived,
        ])
    }

    // six metres after a turn the stairs are cued together with it, so only a look past the turn warns of them
    @Test
    func stairsRightAfterATurnAreStillWarned() throws {
        let walk = walkAtTwoMetresASecond(try closeStepsRoute([
            (6, 270, .turnLeft, "Turn left onto the walkway.", false),
            (40, 270, .stairs, "Take the stairs.", false),
        ]))
        let kinds = cueKinds(walk.logged)
        let warning = try #require(kinds.firstIndex(of: .prepare(step: 2, distance: 0)))
        #expect(warning < (try #require(kinds.firstIndex(of: .now(step: 1)))))
        #expect(kinds.filter { $0 == .prepare(step: 2, distance: 0) }.count == 1)
    }

    @Test(arguments: [30.0, 5.0])
    func stairsNearTheStartAreWarnedOnTheFirstFix(_ firstLeg: Double) throws {
        func walk(_ kind: ManeuverKind) throws -> Walk {
            var walk = Walk(try syntheticRoute([
                (0, firstLeg, .depart, "Walk north."), (270, 50, kind, "Take the stairs down."),
            ]))
            walk.feed(onRoute([0]))
            return walk
        }
        let stairs = try walk(.stairs).logged
        #expect(stairs.first == Logged(0, .prepare(step: 1, distance: firstLeg)))
        // inside nowDistance the warning comes just before the cue
        let rest = Array(stairs.map(\.event).dropFirst())
        #expect(rest == (firstLeg > RouteProgressTracker.nowDistance ? [] : [Event.now(step: 1)]))
        #expect(!cueKinds(try walk(.turnLeft).logged).contains(.prepare(step: 1, distance: 0)))
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

// MARK: Field walks

/// North 100 m, right 40 m, right again and south 100 m, then left and east 100 m: round a block, with the way back
/// 40 m from the way out.
private func blockRoute() throws -> NavigationRoute {
    try syntheticRoute([
        (0, 100, .depart, "Walk north."), (90, 40, .turnRight, "Turn right."),
        (180, 100, .turnRight, "Turn right."), (90, 100, .turnLeft, "Turn left."),
    ])
}

/// Seconds from the fix at `index` to the first off route, if any.
private func secondsToOffRoute(_ walk: Walk, from index: Int) -> Int? {
    walk.logged.first { $0.fix >= index && $0.event == .offRoute }.map { $0.fix - index }
}

private func isTurnCue(_ event: Event) -> Bool {
    switch event {
    case .prepare, .now, .passedTurnConfirmation: true
    default: false
    }
}

/// Turns passed without a word: no `.now` before, and on the fix that passed them neither a confirmation nor a cue
/// for a later step, which says what comes next instead.
private func skippedTurns(in walk: Walk) -> [Int] {
    var skipped: [Int] = []
    var previous = 1
    for (fix, state) in walk.states.enumerated() where state.nextStepIndex > previous {
        let events = walk.logged.filter { $0.fix == fix }.map(\.event)
        for step in previous..<state.nextStepIndex {
            let cued = walk.logged.contains { $0.fix <= fix && $0.event == .now(step: step) }
            let spoken = events.contains {
                switch $0 {
                case .passedTurnConfirmation, .missedTurn: true
                case let .prepare(later, _), let .now(later): later > step
                default: false
                }
            }
            if !cued, !spoken { skipped.append(step) }
        }
        previous = state.nextStepIndex
    }
    return skipped
}

/// Walks like those of a field test outdoors: walking at 1.4 m/s with a fix a second, a position error that drifts,
/// and a course that is sometimes too rough to use.
struct RouteProgressTrackerFieldWalkTests {
    // The far side of the block is 40 m away, nearer than the 20 m limit once more than half way across. Measured from
    // it, as before, the walk was never off route, and progress skipped both turns when it got there.
    @Test
    func walkingAcrossABlockToTheWayBackIsOffRoute() throws {
        var walk = Walk(try blockRoute())
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 30)))
        let start = walk.fixCount
        let across = (1...40).map { (along: 29.4, lateral: 1.4 * Double($0)) }
        walk.feed(walking(TripWalk.fixes(on: walk.tracker.route, path: across, start: walk.nextTime), course: 90))

        // past 20 m first at 21 m (fix 15), so 5 s later at fix 20, 28 m across: before reaching the far side
        let afterStart = walk.logged.drop { $0.fix < start }
        #expect(afterStart.first == Logged(start + 19, .offRoute))
        #expect(!afterStart.prefix { $0.event != .offRoute }.contains { isTurnCue($0.event) })
    }

    // Outdoors one course in a few is rougher than the 45° a walking direction needs. Such a fix ended the run before,
    // leaving only the 30 m rule, at fix 32.
    @Test
    func walkingAwayWithSomeRoughCoursesIsStillOffRouteQuickly() throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        let start = walk.fixCount
        let detour = (1...40).map { (along: 99.4, lateral: -min(1.4 * Double($0), 40)) }
        let fixes = walking(TripWalk.fixes(on: route, path: detour, start: walk.nextTime), course: 270)
            .enumerated().map { index, fix in
                var fix = fix
                fix.courseAccuracy = index.isMultiple(of: 2) ? 60 : 20
                return fix
            }
        walk.feed(fixes)

        // past 20 m first at fix 15, whose course is rough; counted from fix 16, with 3 usable courses over 5 s by fix
        // 22, the next with a usable course after fix 21
        #expect(Array(walk.logged.drop { $0.fix < start }) == [Logged(start + 21, .offRoute)])
    }

    @Test(arguments: [
        // one fix short of the limit, as noise gives, doesn't end the run
        ([17], 19),
        // two in a row do: it starts again at fix 19, so 5 s later at fix 24
        ([17, 18], 23),
    ])
    func walkingAwayToleratesOneFixShortOfTheLimit(_ short: [Int], _ offRouteFix: Int) throws {
        let route = try cornerRoute()
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 100)))
        let start = walk.fixCount
        let detour = (1...40).map { index in
            (along: 99.4, lateral: short.contains(index) ? -19 : -min(1.4 * Double(index), 40))
        }
        walk.feed(walking(TripWalk.fixes(on: route, path: detour, start: walk.nextTime), course: 270))

        #expect(Array(walk.logged.drop { $0.fix < start }) == [Logged(start + offRouteFix, .offRoute)])
    }

    // Before, a rough course or a fix nearer than the run's first, both common with real GPS, ended the run, so
    // these took 18 to 37 s, half of them 35 s or more.
    @Test(arguments: [90.0, 270.0])
    func realisticWalksOffTheRouteAreOffRouteWithinTwentyFiveSeconds(_ bearing: Double) throws {
        let route = try syntheticRoute([(0, 300, .depart, "Walk north.")])
        let path = FieldWalk.path(on: route, leaving: 100, bearing: bearing, seconds: 60)
        let leftAt = TripWalk.distances(from: 0, to: 100).count
        for seed in 1...6 as ClosedRange<UInt64> {
            var walk = Walk(route)
            walk.feed(FieldWalk.fixes(along: path, accuracy: 5...10, courseAccuracy: 10...70, seed: seed))
            let seconds = try #require(secondsToOffRoute(walk, from: leftAt), "seed \(seed)")
            #expect(seconds <= 25, "seed \(seed)")
        }
    }

    // Before, these were off route after 48 to 72 s or never, and progress could jump to the far side. With fixes
    // accurate to 20 m the limits reach 30 m, so some take over half a minute.
    @Test
    func realisticWalksAcrossABlockAreOffRouteBeforeAnyTurnCue() throws {
        let route = try blockRoute()
        let path = FieldWalk.path(on: route, leaving: 30, bearing: 90, seconds: 60)
        let leftAt = TripWalk.distances(from: 0, to: 30).count
        for seed in 1...6 as ClosedRange<UInt64> {
            var walk = Walk(route)
            walk.feed(FieldWalk.fixes(along: path, accuracy: 5...20, courseAccuracy: 10...70, seed: seed))
            let seconds = try #require(secondsToOffRoute(walk, from: leftAt), "seed \(seed)")
            #expect(seconds <= 40, "seed \(seed)")
            let beforeOffRoute = walk.logged.prefix { $0.event != .offRoute }
            #expect(!beforeOffRoute.contains { isTurnCue($0.event) }, "seed \(seed)")
        }
    }

    // walking beside the route, including on the inside of each corner, where the leg after it is nearer, with no
    // turn passed unheard
    @Test(arguments: [0.0, -12, 18])
    func realisticWalksAlongTheRouteStayOnIt(_ lateral: Double) throws {
        let routes = [
            try syntheticRoute([(0, 300, .depart, "Walk north.")]),
            try syntheticRoute([(0, 150, .depart, "Walk north."), (90, 150, .turnRight, "Turn right.")]),
            try blockRoute(),
            try syntheticRoute([
                (0, 60, .depart, "Walk north."), (90, 30, .turnRight, "Turn right."), (0, 60, .turnLeft, "Turn left."),
                (270, 30, .turnLeft, "Turn left."), (0, 60, .turnRight, "Turn right."),
            ]),
        ]
        for (index, route) in routes.enumerated() {
            for seed in 1...10 as ClosedRange<UInt64> {
                var walk = Walk(route)
                let path = FieldWalk.path(on: route, lateral: lateral)
                walk.feed(FieldWalk.fixes(along: path, accuracy: 5...10, courseAccuracy: 10...70, seed: seed))
                #expect(!walk.logged.contains { $0.event == .offRoute }, "route \(index), seed \(seed)")
                #expect(walk.states.last?.nextStepIndex == route.steps.count - 1, "route \(index), seed \(seed)")
                #expect(skippedTurns(in: walk).isEmpty, "route \(index), seed \(seed)")
            }
        }
    }

    // Crossing a switchback near its end is no longer than cutting the inside of a corner, so it can't be told from
    // walking the route; the docs' known limits say so. Crossing it further from its end is off route, before the turns.
    @Test(arguments: [
        // 10 m before the end of a 15 m-wide switchback: progress moves to the way back, and "Continue for …" is the
        // only word, so the two turns of the switchback go unsaid
        (10.0, false),
        (35, true),
    ])
    func crossingASwitchbackIsOffRouteOnlyFarFromItsEnd(_ beforeEnd: Double, _ isOffRoute: Bool) throws {
        let route = try syntheticRoute([
            (0, 60, .depart, "Walk north."), (90, 15, .turnRight, "Turn right."),
            (180, 60, .turnRight, "Turn right."), (90, 60, .turnLeft, "Turn left."),
        ])
        var walk = Walk(route)
        walk.feed(onRoute(TripWalk.distances(from: 0, to: 60 - beforeEnd)))
        let start = walk.fixCount
        let along = walk.tracker.route.totalDistance - (walk.states.last?.distanceRemaining ?? 0)
        let across = (1...30).map { (along: along, lateral: 1.4 * Double($0)) }
        walk.feed(walking(TripWalk.fixes(on: route, path: across, start: walk.nextTime), course: 90))

        let afterStart = walk.logged.drop { $0.fix < start }
        #expect(afterStart.contains { $0.event == .offRoute } == isOffRoute)
        if !isOffRoute {
            #expect(afterStart.map(\.event) == [.passedTurnConfirmation(step: 2)])
            #expect(try #require(walk.states.last).nextStepIndex == 3)
        }
    }
}
