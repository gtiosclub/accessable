import Foundation

/// Follows a walk along one `NavigationRoute` from location fixes and decides which guidance is due.
///
/// Deterministic: all time comes from fix timestamps, so a recorded walk always replays the same way. Wording,
/// delivery and the clock-based weak-signal warning belong to the caller. A reroute needs a new tracker, because
/// every window and flag here refers to this route's geometry.
struct RouteProgressTracker {
    struct Progress: Equatable, Sendable {
        /// Index into `route.steps` of the next maneuver. Never decreases, and stops at the arrive step.
        var nextStepIndex: Int
        /// Metres along the route, at least 0.
        var distanceToNextStep: Double
        /// Metres along the route from accepted progress to the end.
        var distanceRemaining: Double
        var isOffRoute: Bool
    }

    enum GuidanceEvent: Equatable, Sendable {
        /// The step is `distance` metres ahead along the route.
        case prepare(step: Int, distance: Double)
        /// Make the step's maneuver now.
        case now(step: Int)
        /// The step was passed before its `.now` could fire. Confirm the way on rather than announce the maneuver,
        /// which would make the user turn twice. Not emitted alongside a cue for a later step, which already says
        /// what comes next.
        case passedTurnConfirmation(step: Int)
        /// The user walked straight on past the step's vertex, which is `distanceBack` metres behind them.
        case missedTurn(step: Int, distanceBack: Double)
        /// Moving away from the route at the start without making progress along it.
        case wrongWay
        case offRoute
        case backOnRoute
        /// Always alone and last: later fixes are ignored.
        case arrived
    }

    struct Update: Equatable, Sendable {
        var state: Progress
        /// In delivery order.
        var events: [GuidanceEvent]
    }

    let route: NavigationRoute

    private let startedAt: Date
    /// Per step, the direction of travel arriving at its vertex, when the turn there is sharp enough that walking
    /// straight on misses it.
    private let straightOnBearings: [Double?]
    private var lastFixTime: Date?
    /// Metres along the route of the last projection that passed the progress gate.
    private var progress = 0.0
    /// Progress from the accepted fix before the latest, so a step passes only when two fixes in a row are past it.
    private var previousProgress = 0.0
    private var progressTime: Date
    private var nextStepIndex: Int
    private var isOffRoute = false
    private var hasArrived = false

    private var prepareDone: [Bool]
    private var nowDone: [Bool]
    private var missedTurnDone: [Bool]
    /// The highest step a cue check has looked at, so a short leg's cue fires only on the first fix that sees it.
    private var sightedStep = -1
    private var missedTurnRun: (since: Date, misses: Int)?
    private var offRouteRun: (first: LocationSample, count: Int)?
    private var rejoinSince: Date?
    private var wrongWayOrigin: (coordinate: GeoCoordinate, progress: Double, offset: Double)?
    private var wrongWayDone = false

    // the trip's first fix can be a few seconds older than the trip; anything older is a cached position
    private static let maximumFixAgeAtStart: TimeInterval = 5
    // rougher fixes can't tell neighbouring paths apart, so they are ignored
    private static let maximumUsableAccuracy: Double = 25
    // a fix this close sideways is on the path even when its accuracy claims better
    private static let minimumLateralGate: Double = 20
    // a ceiling well above a brisk walk, so GPS lag catching up still counts while a jump faster than this doesn't
    private static let maximumWalkingSpeed: Double = 3
    // how far a single fix's error can push progress ahead
    private static let maximumNoiseAllowance: Double = 20
    // dense geometry needs enough segments, sparse fixes need enough distance
    private static let forwardWindowSegments = 10
    private static let forwardWindowDistance: Double = 100
    // only a fix this far from every segment ahead looks behind, so noise can't drag progress back
    private static let backwardSearchOffset: Double = 25
    private static let backwardSearchSegments = 3
    // identical geometry, such as an out-and-back leg, ties to rounding
    private static let sharedGeometryTolerance: Double = 0.01
    // standing still on one leg of shared geometry mustn't build up enough allowance to jump onto the other
    private static let sharedGeometryElapsedLimit: TimeInterval = 10
    // past the vertex by more than GPS noise, so a fix near the corner doesn't count as the turn made
    private static let passedMargin: Double = 5
    /// Metres before a step that its `.prepare` falls due: about 30 s of walking, time to get ready without forgetting.
    static let prepareDistance: Double = 40
    /// Metres before a step that its `.now` falls due: about 6 s of walking, time to hear the cue and turn. Steps this
    /// close together are cued together.
    static let nowDistance: Double = 8
    // shorter legs follow the previous maneuver too closely for a warning at the usual distance, so they get the
    // short-leg one instead
    private static let minimumPrepareLeg: Double = 25
    // a short leg first seen this far out still gets a warning, since its normal one never could
    private static let shortLegPrepareDistance: Double = 20
    // wider than a sidewalk plus typical urban GPS error
    private static let offRouteDistance: Double = 30
    private static let offRouteAccuracyFactor = 1.5
    // several fixes over time while moving, so drift at a crosswalk or a multipath burst doesn't trigger it
    private static let offRouteFixes = 3
    private static let offRouteDuration: TimeInterval = 10
    private static let offRouteMovement: Double = 8
    // close enough to be on the path again
    private static let rejoinDistance: Double = 15
    // two fixes this far apart confirm a rejoin or a missed turn, so one stray fix can't
    private static let confirmationSpacing: TimeInterval = 2
    // walking straight past a gentler bend stays too near the route to tell from noise; off-route covers it, though
    // at 30° only after about 60 m
    private static let missedTurnMinimumAngle: Double = 60
    // clearly past the corner, beyond noise around it
    private static let missedTurnDistance: Double = 15
    // without a compass, starting in the wrong direction shows only as movement away from the route without progress
    private static let wrongWayMovement: Double = 10
    // both ends of that movement must be precise, since a rough fix moves by its own error. With no such fix in the
    // first 40 m there is no warning, which beats a false "turn around".
    private static let wrongWayMaximumAccuracy: Double = 10
    private static let wrongWayRetreat: Double = 5
    private static let wrongWayProgress: Double = 3
    private static let wrongWayWindow: Double = 40
    // close enough to find the entrance from the arrival description
    private static let arrivalDistance: Double = 10
    // a raw fix near the end counts only when precise and near the end of the route, so a loop that ends where it
    // starts doesn't arrive on its first fix
    private static let rawArrivalAccuracy: Double = 15
    private static let rawArrivalWindow: Double = 50

    init(route: NavigationRoute, startedAt: Date) {
        self.route = route
        self.startedAt = startedAt
        straightOnBearings = route.steps.map { Self.straightOnBearing(at: $0.coordinateIndex, on: route) }
        progressTime = startedAt
        nextStepIndex = min(1, route.steps.count - 1)
        prepareDone = Array(repeating: false, count: route.steps.count)
        nowDone = prepareDone
        missedTurnDone = prepareDone
        // the start announcement speaks the first instruction, which covers a step this close
        if distance(toStep: nextStepIndex) <= Self.prepareDistance {
            prepareDone[nextStepIndex] = true
        }
    }

    /// Records that the caller has already spoken the step's prepare, as when resuming, so the tracker doesn't
    /// repeat it.
    mutating func markPrepared(step: Int) {
        prepareDone[step] = true
    }

    /// Gives the step's `.now` again on a later fix, for a caller that couldn't deliver it, as when paused meanwhile.
    mutating func rearmNow(step: Int) {
        nowDone[step] = false
    }

    var state: Progress {
        Progress(
            nextStepIndex: nextStepIndex,
            distanceToNextStep: max(distance(toStep: nextStepIndex), 0),
            distanceRemaining: route.totalDistance - progress,
            isOffRoute: isOffRoute
        )
    }

    /// Ignores a fix that is invalid, not newer than the last one, cached from before the trip, or less precise than
    /// 25 m.
    ///
    /// With `emitsCues` false, as while paused, progress and off-route state still update, but no `.prepare`, `.now`,
    /// `.passedTurnConfirmation`, `.missedTurn` or `.wrongWay` is emitted or used up, so the right cue still fires
    /// once cues resume. `.offRoute`, `.backOnRoute` and `.arrived` are always emitted.
    mutating func update(with sample: LocationSample, emitsCues: Bool = true) -> Update {
        guard !hasArrived, isAdmissible(sample) else { return Update(state: state, events: []) }
        guard sample.horizontalAccuracy <= Self.maximumUsableAccuracy else {
            lastFixTime = sample.timestamp
            return Update(state: state, events: [])
        }
        let projection = isOffRoute ? route.projection(of: sample.coordinate) : forwardFirstProjection(of: sample)
        guard projection.distanceAlongRoute.isFinite, projection.sideOffset.isFinite else {
            return Update(state: state, events: [])
        }
        lastFixTime = sample.timestamp

        var events: [GuidanceEvent] = []
        if isOffRoute {
            if rejoins(sample, at: projection) { events.append(.backOnRoute) }
        } else {
            moveProgress(sample, to: projection)
            if wrongWayOrigin == nil, sample.horizontalAccuracy <= Self.wrongWayMaximumAccuracy {
                wrongWayOrigin = (sample.coordinate, progress, abs(projection.sideOffset))
            }
            if emitsCues {
                if isWrongWay(sample, at: projection) { events.append(.wrongWay) }
                if let missedTurn = missedTurn(sample, at: projection) { events.append(missedTurn) }
            } else {
                missedTurnRun = nil
            }
            if leavesRoute(sample, at: projection) { events.append(.offRoute) }
        }

        let passed = passSteps()
        if isAtDestination(sample) {
            hasArrived = true
            nextStepIndex = route.steps.count - 1
            return Update(state: state, events: [.arrived])
        }
        if emitsCues, !isOffRoute {
            events += turnCues(passed: passed)
        }
        return Update(state: state, events: events)
    }

    private func isAdmissible(_ sample: LocationSample) -> Bool {
        guard sample.coordinate.latitude.isFinite, sample.coordinate.longitude.isFinite,
              sample.horizontalAccuracy.isFinite, sample.horizontalAccuracy >= 0,
              sample.timestamp.timeIntervalSinceReferenceDate.isFinite,
              sample.timestamp >= startedAt.addingTimeInterval(-Self.maximumFixAgeAtStart) else { return false }
        return lastFixTime.map { sample.timestamp > $0 } ?? true
    }

    /// Searches ahead of accepted progress first, so on switchbacks and out-and-back legs the fix lands on the leg
    /// being walked rather than one that merely passes nearby.
    private func forwardFirstProjection(of sample: LocationSample) -> RouteProjection {
        let segmentCount = route.coordinates.count - 1
        let current = segment(containing: progress)
        var end = min(current + Self.forwardWindowSegments, segmentCount)
        while end < segmentCount,
              route.cumulativeDistances[end] - route.cumulativeDistances[current] < Self.forwardWindowDistance {
            end += 1
        }
        let here = route.projection(of: sample.coordinate, segments: current..<current + 1)
        var best = here
        if current + 1 < end {
            let ahead = route.projection(of: sample.coordinate, segments: current + 1..<end)
            let difference = abs(ahead.sideOffset) - abs(here.sideOffset)
            if abs(difference) <= Self.sharedGeometryTolerance {
                // shared geometry, such as an out-and-back leg, ties either way by rounding: the leg ahead only once
                // it is in walking reach, so a turnaround is followed but standing still never jumps
                let reach = progressAllowance(for: sample, elapsedLimit: Self.sharedGeometryElapsedLimit)
                if ahead.distanceAlongRoute - progress <= reach { best = ahead }
            } else if difference < 0 {
                best = ahead
            }
        }
        if abs(best.sideOffset) > Self.backwardSearchOffset, current > 0 {
            let behind = route.projection(of: sample.coordinate,
                                          segments: max(current - Self.backwardSearchSegments, 0)..<current)
            if abs(behind.sideOffset) < abs(best.sideOffset) { best = behind }
        }
        return best
    }

    /// The last segment whose start is at or before `distance`.
    private func segment(containing distance: Double) -> Int {
        var low = 0
        var high = route.coordinates.count - 2
        while low < high {
            let middle = (low + high + 1) / 2
            if route.cumulativeDistances[middle] <= distance {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// Metres progress may gain from this fix: walking speed since progress last moved, up to `elapsedLimit` seconds,
    /// plus one fix's error.
    private func progressAllowance(for sample: LocationSample, elapsedLimit: TimeInterval = .infinity) -> Double {
        let elapsed = min(max(sample.timestamp.timeIntervalSince(progressTime), 0), elapsedLimit)
        return Self.maximumWalkingSpeed * elapsed + min(sample.horizontalAccuracy, Self.maximumNoiseAllowance)
    }

    /// Moves forward only, within `progressAllowance`, so outliers and noise behind are held off.
    private mutating func moveProgress(_ sample: LocationSample, to projection: RouteProjection) {
        guard abs(projection.sideOffset) <= max(Self.minimumLateralGate, sample.horizontalAccuracy) else { return }
        let gain = projection.distanceAlongRoute - progress
        guard gain >= 0, gain <= progressAllowance(for: sample) else { return }
        // walking straight past a sharp turn can project onto the outgoing leg; that isn't the turn made
        if projection.distanceAlongRoute > position(ofStep: nextStepIndex),
           straightOnOvershoot(of: sample, at: projection) != nil {
            return
        }
        previousProgress = progress
        progress = projection.distanceAlongRoute
        progressTime = sample.timestamp
    }

    private mutating func isWrongWay(_ sample: LocationSample, at projection: RouteProjection) -> Bool {
        guard !wrongWayDone, let origin = wrongWayOrigin, sample.horizontalAccuracy <= Self.wrongWayMaximumAccuracy,
              progress < Self.wrongWayWindow,
              progress - origin.progress < Self.wrongWayProgress,
              abs(projection.sideOffset) - origin.offset >= Self.wrongWayRetreat,
              GeoMath.distance(from: origin.coordinate, to: sample.coordinate) >= Self.wrongWayMovement else {
            return false
        }
        wrongWayDone = true
        return true
    }

    /// How far the fix is beyond the next step's vertex along the line straight on through it, and how far from the
    /// vertex, when the fix looks like walking straight past a turn of `missedTurnMinimumAngle` or more: beyond the
    /// vertex, nearer that line than the route, and further from the route than its accuracy explains.
    private func straightOnOvershoot(of sample: LocationSample,
                                     at projection: RouteProjection) -> (along: Double, distance: Double)? {
        guard nextStepIndex < route.steps.count - 1, let bearing = straightOnBearings[nextStepIndex] else {
            return nil
        }
        let vertex = route.coordinates[route.steps[nextStepIndex].coordinateIndex]
        let distance = GeoMath.distance(from: vertex, to: sample.coordinate)
        // planar is exact enough over the tens of metres this is used for
        let angle = (GeoMath.bearing(from: vertex, to: sample.coordinate) - bearing) * .pi / 180
        let along = distance * cos(angle)
        let offset = abs(projection.sideOffset)
        guard along > 0, abs(distance * sin(angle)) < offset, offset > sample.horizontalAccuracy else { return nil }
        return (along, distance)
    }

    /// Needs the user clearly off the route as well as past the vertex. A single fix that falls short doesn't reset
    /// the confirmation, since noise around the line is expected.
    private mutating func missedTurn(_ sample: LocationSample, at projection: RouteProjection) -> GuidanceEvent? {
        guard !missedTurnDone[nextStepIndex], let overshoot = straightOnOvershoot(of: sample, at: projection),
              overshoot.along >= Self.missedTurnDistance,
              abs(projection.sideOffset) >= Self.missedTurnDistance else {
            if let run = missedTurnRun {
                missedTurnRun = run.misses == 0 ? (run.since, 1) : nil
            }
            return nil
        }
        guard let run = missedTurnRun else {
            missedTurnRun = (sample.timestamp, 0)
            return nil
        }
        guard sample.timestamp.timeIntervalSince(run.since) >= Self.confirmationSpacing else {
            missedTurnRun = (run.since, 0)
            return nil
        }
        missedTurnDone[nextStepIndex] = true
        missedTurnRun = nil
        return .missedTurn(step: nextStepIndex, distanceBack: overshoot.distance)
    }

    private mutating func leavesRoute(_ sample: LocationSample, at projection: RouteProjection) -> Bool {
        let limit = max(Self.offRouteDistance, Self.offRouteAccuracyFactor * sample.horizontalAccuracy)
        guard abs(projection.sideOffset) > limit else {
            offRouteRun = nil
            return false
        }
        var run = offRouteRun ?? (first: sample, count: 0)
        run.count += 1
        offRouteRun = run
        guard run.count >= Self.offRouteFixes,
              sample.timestamp.timeIntervalSince(run.first.timestamp) >= Self.offRouteDuration,
              GeoMath.distance(from: run.first.coordinate, to: sample.coordinate) >= Self.offRouteMovement else {
            return false
        }
        isOffRoute = true
        offRouteRun = nil
        rejoinSince = nil
        missedTurnRun = nil
        return true
    }

    /// Accepts the rejoin point even behind progress, since the user may have walked back to the route.
    private mutating func rejoins(_ sample: LocationSample, at projection: RouteProjection) -> Bool {
        guard abs(projection.sideOffset) <= Self.rejoinDistance else {
            rejoinSince = nil
            return false
        }
        guard let since = rejoinSince else {
            rejoinSince = sample.timestamp
            return false
        }
        guard sample.timestamp.timeIntervalSince(since) >= Self.confirmationSpacing else { return false }
        isOffRoute = false
        rejoinSince = nil
        progress = projection.distanceAlongRoute
        // already confirmed by two fixes
        previousProgress = progress
        progressTime = sample.timestamp
        for index in nextStepIndex..<route.steps.count {
            prepareDone[index] = false
            nowDone[index] = false
            missedTurnDone[index] = false
        }
        sightedStep = nextStepIndex - 1
        return true
    }

    /// Passed once two accepted fixes in a row are `passedMargin` past the vertex, so one noisy fix that projects past
    /// it can't. Returns the steps passed, in order.
    private mutating func passSteps() -> [Int] {
        var passed: [Int] = []
        while nextStepIndex < route.steps.count - 1,
              min(previousProgress, progress) - position(ofStep: nextStepIndex) >= Self.passedMargin {
            passed.append(nextStepIndex)
            nextStepIndex += 1
        }
        if !passed.isEmpty { missedTurnRun = nil }
        return passed
    }

    /// Progress near the end arrives even with a step left unpassed, since a step that close to the end can't be
    /// passed by `passedMargin`.
    private func isAtDestination(_ sample: LocationSample) -> Bool {
        if route.totalDistance - progress <= Self.arrivalDistance { return true }
        guard nextStepIndex == route.steps.count - 1, let end = route.coordinates.last,
              sample.horizontalAccuracy <= Self.rawArrivalAccuracy,
              progress >= route.totalDistance - Self.rawArrivalWindow else { return false }
        let radius = max(Self.arrivalDistance, sample.horizontalAccuracy)
        return GeoMath.distance(from: sample.coordinate, to: end) <= radius
    }

    private mutating func turnCues(passed: [Int]) -> [GuidanceEvent] {
        var events: [GuidanceEvent] = []
        let index = nextStepIndex
        let isFirstSight = index > sightedStep
        sightedStep = max(sightedStep, index)
        let remaining = distance(toStep: index)
        let isDue = leg(before: index) >= Self.minimumPrepareLeg
            ? remaining <= Self.prepareDistance
            : isFirstSight && remaining <= Self.shortLegPrepareDistance
        if !prepareDone[index], allowsPrepare(index), remaining > Self.nowDistance, isDue {
            prepareDone[index] = true
            events.append(.prepare(step: index, distance: remaining))
        }
        // the first step not yet cued: one cued with an earlier group may not be passed yet, and the step after it
        // can come up before it is
        var cueIndex = index
        while cueIndex < route.steps.count - 1, nowDone[cueIndex] { cueIndex += 1 }
        // not once past the vertex: the user may already have turned
        if cueIndex < route.steps.count - 1, (0...Self.nowDistance).contains(distance(toStep: cueIndex)) {
            nowDone[cueIndex] = true
            prepareDone[cueIndex] = true
            let speaks = expectsNow(cueIndex)
            if speaks { events.append(.now(step: cueIndex)) }
            events += cueGroup(after: cueIndex, spoken: speaks)
        }
        // with several steps passed in one fix, one confirmation from the last is all that's still useful, and none
        // when a cue for what comes next is already being given
        if events.isEmpty, let last = passed.last, passed.contains(where: { expectsNow($0) && !nowDone[$0] }) {
            events.append(.passedTurnConfirmation(step: last))
        }
        return events
    }

    /// Steps following `step` each within `nowDistance` of the one before come up before the user could hear a cue
    /// at each, so they are cued now with it: covered without a word when the step before was spoken and named them
    /// (multi-cue), said straight after otherwise. Only steps within twice `nowDistance` of `step` join, so a long run
    /// of close steps isn't read out at once; the rest are cued as they are reached. Returns their `.now` events.
    private mutating func cueGroup(after step: Int, spoken: Bool) -> [GuidanceEvent] {
        var events: [GuidanceEvent] = []
        var previous = step
        var previousSpoken = spoken
        var next = step + 1
        while next < route.steps.count - 1, !nowDone[next],
              position(ofStep: next) - position(ofStep: previous) <= Self.nowDistance,
              position(ofStep: next) - position(ofStep: step) <= 2 * Self.nowDistance {
            nowDone[next] = true
            prepareDone[next] = true
            let covered = previousSpoken && route.steps[previous].announcesNextStep
            let speaks = !covered && expectsNow(next)
            if speaks { events.append(.now(step: next)) }
            previous = next
            previousSpoken = speaks
            next += 1
        }
        return events
    }

    /// Metres along the route from accepted progress to the step's vertex; negative once past it.
    private func distance(toStep index: Int) -> Double {
        position(ofStep: index) - progress
    }

    /// Metres from the route start to the step's vertex.
    private func position(ofStep index: Int) -> Double {
        route.cumulativeDistances[route.steps[index].coordinateIndex]
    }

    private func leg(before index: Int) -> Double {
        position(ofStep: index) - (index > 0 ? position(ofStep: index - 1) : 0)
    }

    /// A multi-cue previous step already said this one, and "Continue" needs no warning.
    private func allowsPrepare(_ index: Int) -> Bool {
        !followsMultiCue(index) && !route.steps[index].spokenInstruction.hasPrefix("Continue")
    }

    /// The arrive step has its own event, and a "Continue" a multi-cue step already said needs no repeat.
    private func expectsNow(_ index: Int) -> Bool {
        index < route.steps.count - 1
            && !(followsMultiCue(index) && route.steps[index].spokenInstruction.hasPrefix("Continue"))
    }

    private func followsMultiCue(_ index: Int) -> Bool {
        index > 0 && route.steps[index - 1].announcesNextStep
    }

    /// Bearings from neighbouring vertices at least a metre away, so a near-zero segment doesn't give a noisy one.
    private static func straightOnBearing(at vertexIndex: Int, on route: NavigationRoute) -> Double? {
        let distances = route.cumulativeDistances
        let vertex = route.coordinates[vertexIndex]
        guard let before = (0..<vertexIndex).last(where: { distances[vertexIndex] - distances[$0] >= 1 }),
              let after = (vertexIndex + 1..<route.coordinates.count).first(where: {
                  distances[$0] - distances[vertexIndex] >= 1
              }) else { return nil }
        let incoming = GeoMath.normalizedBearing(GeoMath.bearing(from: vertex, to: route.coordinates[before]) + 180)
        let turn = GeoMath.normalizedBearing(GeoMath.bearing(from: vertex, to: route.coordinates[after]) - incoming)
        return min(turn, 360 - turn) >= missedTurnMinimumAngle ? incoming : nil
    }
}
