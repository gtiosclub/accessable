import Foundation
import os

private let log = Logger(subsystem: "AccessAble", category: "TripManager")

/// Guides a walk along a route: follows location fixes with `RouteProgressTracker`, speaks its cues, reroutes when
/// the user leaves the route, and warns when GPS is too weak to guide.
///
/// Every `await` is a point where `endTrip` or another `startTrip` can run, so each task and handler carries the
/// `generation` it was started for and does nothing once it is stale. State changes happen before the next `await`.
actor TripManager: TripStateProviding {
    private nonisolated let states = Broadcaster<TripState>(replaysLatest: true)
    private nonisolated let routes = Broadcaster<NavigationRoute?>(replaysLatest: true)

    private let location: any LocationProvider
    private let routing: any RoutingService
    private let announcements: any AnnouncementEngineProtocol
    private let landmarks: any LandmarkObserving
    /// Read when a trip starts, not at launch: loading them parses a large bundled file.
    private let campusBuildings: @Sendable () -> [CampusBuilding]
    /// Read when a trip starts or reroutes, like `campusBuildings`.
    private let campusCrossings: @Sendable () -> [CampusCrossing]
    private let setTripTracking: @Sendable (Bool) async -> Void
    private let distances: DistanceSettings
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Bumped by `startTrip` and `endTrip`; a task from an older trip stops at its next check.
    private var generation = 0
    /// Bumped on each reroute, so a reroute answer or cue check for a replaced route is dropped.
    private var routeVersion = 0
    private var tripID = UUID()
    private var phase: TripPhase = .planning
    private var arrivedWhilePaused = false
    private var destination: Destination?
    private var route: NavigationRoute?
    private var tracker: RouteProgressTracker?
    /// The current route's crossings, in the order the tracker's `.crossing` indices refer to.
    private var routeCrossings: [RouteCrossing] = []
    private var progress: RouteProgressTracker.Progress?
    private var landmarkMatcher: LandmarkMatcher?
    private var entranceGuide = EntranceGuide()

    private var trackingTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var rerouteTask: Task<Void, Never>?
    private var landmarkTask: Task<Void, Never>?
    private var headingTask: Task<Void, Never>?
    private var cueChecks: [Task<Void, Never>] = []

    /// Turn cues submitted and waiting for their delivery check, and those of them the engine has delivered.
    private var pendingCueIDs: Set<UUID> = []
    private var deliveredIDs: Set<UUID> = []
    private var missedTurnStep: Int?
    private var rerouteCount = 0
    private var lastRerouteRequest: Date?
    private var hasRerouted = false
    /// Where an asked-for reroute starts: the latest fix precise enough to start a route from.
    private var lastPreciseFix: GeoCoordinate?
    /// The latest fix, however rough, for saying which way the path or the destination lies only when it is precise.
    private var lastFix: LocationSample?
    private var headingEstimator = HeadingEstimator()
    private var tripStartedAt = Date.distantPast
    private var lastGoodFixAt: Date?
    private var isSignalWeak = false

    // the public routing server is shared and slow to recover; this spaces requests and bounds a bad walk
    private static let rerouteInterval: TimeInterval = 30
    // a reroute that came back shows the server is answering, and a user still lost shouldn't wait as long again
    private static let reroutedInterval: TimeInterval = 15
    private static let maximumReroutes = 5
    // a new route from a rough fix would start on the wrong side of the street, and a direction from one can point
    // the wrong way
    private static let rerouteAccuracy: Double = 20
    // a target nearer than twice the fix's accuracy may lie on either side of the user
    private static let directionAccuracyFactor: Double = 2
    // seconds; after a dropout the last fix is no longer where the user is. The tracker's start rule uses the same
    // limit for a cached fix
    private static let directionFixAge: TimeInterval = 5
    // VoiceOver moves focus when the Start button disappears; speaking at once would be cut off by that
    private static let startDelay: Duration = .milliseconds(750)
    private static let watchdogInterval: Duration = .seconds(5)
    // the first fixes of a trip are often slow, so don't warn before then
    private static let watchdogGrace: TimeInterval = 5
    // guidance from fixes rougher than this is unreliable
    private static let weakSignalAccuracy: Double = 30
    private static let weakSignalWait: TimeInterval = 10
    // a sign matters while it is in view, a few steps' walk
    private static let landmarkLifetime: TimeInterval = 6
    // metres; nearer than this the building is on both sides of the path, or the path goes through it
    private static let landmarkSideMinimum: Double = 3
    // metres along the route past the user: far enough that GPS error doesn't swing the bearing, near enough to be
    // the path in front of them
    private static let pathLookAhead: Double = 15
    // metres; nearer than this the direction to the destination is GPS noise
    private static let arrivalDirectionMinimum: Double = 5

    init(
        location: any LocationProvider,
        routing: any RoutingService,
        announcements: any AnnouncementEngineProtocol,
        landmarks: any LandmarkObserving = PlaceholderLandmarkProvider(),
        campusBuildings: @escaping @Sendable () -> [CampusBuilding] = { CampusLandmarks.buildings },
        campusCrossings: @escaping @Sendable () -> [CampusCrossing] = { CampusCrossings.all },
        setTripTracking: @escaping @Sendable (Bool) async -> Void = { _ in },
        distances: DistanceSettings = DistanceSettings(units: .metres),
        now: @escaping @Sendable () -> Date = { .now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.location = location
        self.routing = routing
        self.announcements = announcements
        self.landmarks = landmarks
        self.campusBuildings = campusBuildings
        self.campusCrossings = campusCrossings
        self.setTripTracking = setTripTracking
        self.distances = distances
        self.now = now
        self.sleep = sleep
        states.send(TripState(phase: .planning, updatedAt: now()))
    }

    nonisolated func tripStates() -> AsyncStream<TripState> {
        states.stream()
    }

    nonisolated func tripRoutes() -> AsyncStream<NavigationRoute?> {
        routes.stream()
    }

    func startTrip(route: NavigationRoute, destination: Destination) async {
        generation += 1
        let generation = generation
        cancelTasks()
        tripID = UUID()
        routeVersion = 0
        phase = .active
        arrivedWhilePaused = false
        self.destination = destination
        self.route = route
        routeCrossings = RouteCrossings.along(route, crossings: campusCrossings())
        let tracker = RouteProgressTracker(route: route, startedAt: now(),
                                           crossings: routeCrossings.map(\.distanceAlongRoute))
        self.tracker = tracker
        progress = tracker.state
        landmarkMatcher = LandmarkMatcher(
            landmarks: RouteLandmarks.along(route, destination: destination, buildings: campusBuildings())
        )
        entranceGuide = EntranceGuide()
        pendingCueIDs = []
        deliveredIDs = []
        missedTurnStep = nil
        rerouteCount = 0
        lastRerouteRequest = nil
        hasRerouted = false
        lastPreciseFix = nil
        lastFix = nil
        headingEstimator = HeadingEstimator()
        tripStartedAt = now()
        lastGoodFixAt = nil
        isSignalWeak = false
        routes.send(route)
        publish(at: now())

        // subscribed before any await, so a fix or delivery can't slip past while this trip is set up
        let samples = location.locationSamples()
        let headings = location.headingSamples()
        let delivered = announcements.deliveredEvents()
        let sightings = landmarks.landmarkObservations()
        headingTask = Task {
            for await sample in headings { self.handle(sample, generation: generation) }
        }
        landmarkTask = Task {
            for await sighting in sightings { await self.handle(sighting, generation: generation) }
        }
        deliveryTask = Task {
            for await event in delivered { self.markDelivered(event.id, generation: generation) }
        }
        trackingTask = Task {
            for await sample in samples { await self.handle(sample, generation: generation) }
        }
        startTask = Task { await self.announceStart(generation: generation) }
        watchdogTask = Task { await self.watchSignal(generation: generation) }
        await setTripTracking(true)
        // an end that ran during the await may have switched it off before this switched it on
        if self.generation != generation, phase == .planning {
            await setTripTracking(false)
        }
    }

    func pauseTrip() async {
        guard phase == .active else { return }
        phase = .paused
        publish(at: now())
        await submit(confirmation("Trip paused."))
    }

    func resumeTrip() async {
        guard phase == .paused else { return }
        let generation = generation
        let version = routeVersion
        if arrivedWhilePaused {
            phase = .arrived
            publish(at: now())
            await submit(confirmation("Trip resumed."))
            guard self.generation == generation, let arrival = arrivalAnnouncement() else { return }
            await submit(arrival)
            return
        }
        phase = .active
        publish(at: now())
        let guidance = resumeAnnouncement()
        await submit(confirmation("Trip resumed."))
        // a reroute that landed meanwhile has its own announcement, and this one is about the old route
        guard self.generation == generation, routeVersion == version, phase == .active, let guidance else { return }
        await submit(guidance)
    }

    func endTrip() async {
        guard phase != .planning else { return }
        generation += 1
        let generation = generation
        cancelTasks()
        phase = .planning
        tracker = nil
        progress = nil
        landmarkMatcher = nil
        routeCrossings = []
        route = nil
        destination = nil
        routes.send(nil)
        states.send(TripState(phase: .planning, updatedAt: now()))
        await setTripTracking(false)
        // a trip started meanwhile shouldn't hear that it ended
        guard self.generation == generation else { return }
        await submit(confirmation("Trip ended."))
    }

    private func cancelTasks() {
        for task in [trackingTask, deliveryTask, startTask, watchdogTask, rerouteTask, landmarkTask, headingTask] {
            task?.cancel()
        }
        for task in cueChecks {
            task.cancel()
        }
        landmarkTask = nil
        headingTask = nil
        trackingTask = nil
        deliveryTask = nil
        startTask = nil
        watchdogTask = nil
        rerouteTask = nil
        cueChecks = []
    }

    // MARK: Fixes

    private func handle(_ sample: LocationSample, generation: Int) async {
        guard self.generation == generation, phase == .active || phase == .paused, var tracker else { return }
        var pending: [(event: AnnouncementEvent, cueStep: Int?)] = []
        // a cached fix says nothing about the signal now
        if sample.horizontalAccuracy <= Self.weakSignalAccuracy,
           now().timeIntervalSince(sample.timestamp) < Self.weakSignalWait {
            lastGoodFixAt = max(lastGoodFixAt ?? .distantPast, sample.timestamp)
            if isSignalWeak {
                isSignalWeak = false
                if phase == .active { pending.append((signalAnnouncement("GPS signal is back.", .normal, 6), nil)) }
            }
        }
        if sample.horizontalAccuracy <= Self.rerouteAccuracy { lastPreciseFix = sample.coordinate }
        // a bearing from a NaN fix would trap when turned into a direction, and a late fix is no longer where they are
        if sample.coordinate.latitude.isFinite, sample.coordinate.longitude.isFinite,
           sample.horizontalAccuracy.isFinite, sample.timestamp >= lastFix?.timestamp ?? .distantPast {
            lastFix = sample
        }
        headingEstimator.update(with: sample)

        let update = tracker.update(with: sample, emitsCues: phase == .active)
        self.tracker = tracker
        progress = update.state
        if update.events.contains(.arrived) {
            await arrive(at: sample.timestamp, generation: generation)
            return
        }
        if let step = missedTurnStep, update.state.nextStepIndex != step { missedTurnStep = nil }
        for case let .missedTurn(step, _) in update.events { missedTurnStep = step }
        if update.events.contains(.backOnRoute) { missedTurnStep = nil }
        publish(at: sample.timestamp)
        // from this fix when it is precise enough, even the one that found the user off the route: the public server
        // is slow, so waiting for the next fix only adds to it
        if wantsReroute, sample.horizontalAccuracy <= Self.rerouteAccuracy {
            requestReroute(from: sample.coordinate, generation: generation)
        }

        guard phase == .active else { return }
        pending += update.events.compactMap { event in
            announcement(for: event, progress: update.state).map { ($0, Self.cueStep(of: event)) }
        }
        for (offset, (event, cueStep)) in pending.enumerated() {
            guard self.generation == generation else { return }
            guard phase == .active else {
                // paused meanwhile: the turn cues not said yet come again on a fix after resuming
                for case let (_, step?) in pending[offset...] { self.tracker?.rearmNow(step: step) }
                return
            }
            // pending before the submit, since the engine can deliver it before the submit returns
            if cueStep != nil { pendingCueIDs.insert(event.id) }
            await submit(event)
            // checked only once actually submitted, so a cue dropped by a pause isn't brought back
            if let cueStep, self.generation == generation, let expiresAt = event.expiresAt {
                scheduleCueCheck(step: cueStep, id: event.id, after: expiresAt.timeIntervalSince(event.createdAt),
                                 generation: generation)
            }
        }
    }

    private func handle(_ sample: HeadingSample, generation: Int) {
        guard self.generation == generation else { return }
        headingEstimator.update(with: sample)
    }

    private static func cueStep(of event: RouteProgressTracker.GuidanceEvent) -> Int? {
        if case let .now(step) = event { step } else { nil }
    }

    private func arrive(at time: Date, generation: Int) async {
        // the heading only words guidance, and the compass runs while it is subscribed
        for task in [watchdogTask, rerouteTask, deliveryTask, headingTask] {
            task?.cancel()
        }
        for task in cueChecks {
            task.cancel()
        }
        cueChecks = []
        pendingCueIDs = []
        deliveredIDs = []
        if phase == .paused {
            arrivedWhilePaused = true
            publish(at: time)
        } else {
            phase = .arrived
            publish(at: time)
            if let arrival = arrivalAnnouncement() { await submit(arrival) }
        }
        guard self.generation == generation else { return }
        // last, since this runs inside the tracking task
        trackingTask?.cancel()
        trackingTask = nil
        await setTripTracking(false)
    }

    private func markDelivered(_ id: UUID, generation: Int) {
        guard self.generation == generation, pendingCueIDs.contains(id) else { return }
        deliveredIDs.insert(id)
    }

    private func publish(at time: Date) {
        guard let route, let progress else { return }
        let step = route.steps[progress.nextStepIndex]
        let instruction = progress.isOffRoute ? offRouteInstruction : step.instruction
        states.send(TripState(
            phase: phase,
            destinationName: destination?.name,
            nextManeuver: Maneuver(kind: step.kind, instruction: instruction,
                                   coordinate: route.coordinates[step.coordinateIndex]),
            distanceToNextManeuver: progress.isOffRoute ? nil : progress.distanceToNextStep,
            distanceRemaining: progress.distanceRemaining,
            updatedAt: time
        ))
    }

    private var offRouteInstruction: String {
        reroutesRemain ? "Off route. Finding a new route." : "Off route. Head back toward the path."
    }

    /// A reroute is in flight or still allowed this trip.
    private var reroutesRemain: Bool {
        rerouteCount < Self.maximumReroutes || rerouteTask != nil
    }

    // MARK: Landmarks

    /// Speaks a sign that matches a building on the route, or near the end a door to head for. Both stay open after
    /// arriving, since the destination's sign and doors are often only in view from outside it.
    private func handle(_ sighting: LandmarkObservation, generation: Int) async {
        guard self.generation == generation, phase == .active || phase == .arrived,
              let route, let progress, var matcher = landmarkMatcher
        else { return }
        let event = matcher.match(sighting, progress: route.totalDistance - progress.distanceRemaining,
                                  remaining: progress.distanceRemaining)
        landmarkMatcher = matcher
        let time = now()
        let text: String
        let key: String
        if let event {
            guard phase == .active || Self.isDestination(event) else { return }
            text = Self.landmarkText(event)
            key = "landmark-\(Self.landmarkName(event))"
        } else if let guidance = entranceGuide.guidance(for: sighting, remaining: progress.distanceRemaining,
                                                        hasArrived: phase == .arrived, at: time) {
            text = guidance
            key = "entrance-\(sighting.key)"
        } else {
            return
        }
        await submit(AnnouncementEvent(
            category: .landmark, priority: .normal, text: text, source: .navigation,
            createdAt: time, expiresAt: time.addingTimeInterval(Self.landmarkLifetime), dedupKey: "\(tripID)-\(key)"
        ))
    }

    /// When CV already read the sign aloud, only what it adds is said, so the name isn't heard twice.
    static func landmarkText(_ event: LandmarkMatcher.Event) -> String {
        switch event {
        case let .passing(landmark, name, wasAnnounced):
            if wasAnnounced { return "You're on track." }
            // a building the route runs right along has no useful side
            guard abs(landmark.sideOffset) >= landmarkSideMinimum else { return "Passing \(name)." }
            return "Passing \(name) on your \(landmark.sideOffset < 0 ? "left" : "right")."
        case let .destination(_, name, wasAnnounced):
            return wasAnnounced ? "That's your destination." : "This is \(name), your destination."
        }
    }

    private static func isDestination(_ event: LandmarkMatcher.Event) -> Bool {
        if case .destination = event { true } else { false }
    }

    private static func landmarkName(_ event: LandmarkMatcher.Event) -> String {
        switch event {
        case let .passing(landmark, _, _), let .destination(landmark, _, _): landmark.name
        }
    }

    // MARK: Rerouting

    private var needsReroute: Bool {
        progress?.isOffRoute == true || missedTurnStep != nil
    }

    private var wantsReroute: Bool {
        guard phase == .active, needsReroute else { return false }
        return canRequestReroute
    }

    private var canRequestReroute: Bool {
        guard rerouteTask == nil, rerouteCount < Self.maximumReroutes else { return false }
        let interval = hasRerouted ? Self.reroutedInterval : Self.rerouteInterval
        return lastRerouteRequest.map { now().timeIntervalSince($0) >= interval } ?? true
    }

    /// A new route from where the user is now, asked for by the user (Route Blocked Ahead's
    /// "find another way") rather than because they left the route. The routing service doesn't
    /// know about the obstacle, so the new route is the best one from here, not one around it.
    func reroute() async {
        guard phase == .active || phase == .paused else { return }
        // with a weak signal the last precise fix is old, and the user has walked on from it
        guard let origin = lastPreciseFix, !isSignalWeak else {
            await submit(maneuver("Couldn't find where you are precisely enough for a new route. Try again in a moment.",
                                  .high, haptic: .attention, expiresIn: 10, key: "reroute-failed"))
            return
        }
        let generation = generation
        await submit(maneuver("Finding a new route from here.", .high, expiresIn: 10, key: "reroute-requested"))
        // the trip may have ended while that was submitted
        guard self.generation == generation, phase == .active || phase == .paused else { return }
        // one already in flight is the user going off route, so its answer is the new route
        guard rerouteTask == nil else { return }
        requestReroute(from: origin, generation: generation, requested: true)
    }

    /// - Parameter requested: Asked for by the user, so it lands even while still on the route.
    private func requestReroute(from origin: GeoCoordinate, generation: Int, requested: Bool = false) {
        guard let destination else { return }
        rerouteCount += 1
        lastRerouteRequest = now()
        let version = routeVersion
        rerouteTask = Task { [routing] in
            let result: Result<NavigationRoute, any Error>
            do {
                result = .success(try await routing.route(from: origin, to: destination.coordinate,
                                                          options: RouteOptions()))
            } catch {
                result = .failure(error)
            }
            await self.finishReroute(result, generation: generation, version: version, requested: requested)
        }
    }

    private func finishReroute(_ result: Result<NavigationRoute, any Error>, generation: Int, version: Int,
                               requested: Bool) async {
        guard self.generation == generation, routeVersion == version else { return }
        rerouteTask = nil
        // back on the route, or arrived, since the request went out
        guard phase == .active || phase == .paused, !arrivedWhilePaused, needsReroute || requested else { return }
        switch result {
        case .success(let newRoute):
            routeVersion += 1
            hasRerouted = true
            route = newRoute
            routeCrossings = RouteCrossings.along(newRoute, crossings: campusCrossings())
            let tracker = RouteProgressTracker(route: newRoute, startedAt: now(),
                                               crossings: routeCrossings.map(\.distanceAlongRoute))
            self.tracker = tracker
            progress = tracker.state
            missedTurnStep = nil
            landmarkMatcher?.replaceLandmarks(
                RouteLandmarks.along(newRoute, destination: destination, buildings: campusBuildings())
            )
            routes.send(newRoute)
            publish(at: now())
            guard phase == .active, let first = newRoute.steps.first else { return }
            await submit(maneuver("New route. \(first.spokenInstruction)", .high, expiresIn: 15, key: "reroute"))
        case .failure(let error):
            guard !(error is CancellationError), phase == .active else { return }
            log.error("Reroute failed: \(error.localizedDescription, privacy: .public)")
            let text = if requested, !needsReroute {
                // still on the route, so there is nothing to walk back to
                "Couldn't get a new route. Keep following the current one."
            } else if rerouteCount < Self.maximumReroutes {
                "Couldn't get a new route. Walk back the way you came."
            } else {
                "Off route. End the trip and choose your destination again."
            }
            await submit(maneuver(text, .high, haptic: .attention, expiresIn: 10, key: "reroute-failed"))
        }
    }

    // MARK: Timed announcements

    private func announceStart(generation: Int) async {
        do { try await sleep(Self.startDelay) } catch { return }
        guard self.generation == generation, phase == .active, let route, let destination,
              let first = route.steps.first else { return }
        let text = "Starting directions to \(destination.name), \(spoken(route.totalDistance)). "
            + (pathSentence().map { $0 + firstTurnPrepare(on: route) } ?? first.spokenInstruction)
        await submit(maneuver(text, .high, expiresIn: 15, key: "start"))
    }

    /// Clock-based rather than fix-based, so it notices when fixes stop arriving at all.
    private func watchSignal(generation: Int) async {
        while true {
            do { try await sleep(Self.watchdogInterval) } catch { return }
            guard self.generation == generation else { return }
            let time = now()
            guard phase == .active, !isSignalWeak, time.timeIntervalSince(tripStartedAt) >= Self.watchdogGrace,
                  time.timeIntervalSince(lastGoodFixAt ?? tripStartedAt) >= Self.weakSignalWait else { continue }
            isSignalWeak = true
            await submit(signalAnnouncement("GPS signal is weak. Directions may be delayed.", .high, 10))
        }
    }

    /// Resubmits a turn cue the engine dropped before speaking, once, while the turn is still ahead.
    private func scheduleCueCheck(step: Int, id: UUID, after lifetime: TimeInterval, generation: Int) {
        let version = routeVersion
        cueChecks.append(Task {
            do { try await self.sleep(.seconds(lifetime)) } catch { return }
            await self.recheckCue(step: step, id: id, generation: generation, version: version)
        })
    }

    private func recheckCue(step: Int, id: UUID, generation: Int, version: Int) async {
        let wasDelivered = deliveredIDs.remove(id) != nil
        pendingCueIDs.remove(id)
        // a missed turn or a new route has its own announcement
        guard self.generation == generation, routeVersion == version, phase == .active, !wasDelivered,
              missedTurnStep != step, let route, let progress, !progress.isOffRoute,
              progress.nextStepIndex <= step else { return }
        let walked = route.totalDistance - progress.distanceRemaining
        let remaining = max(route.cumulativeDistances[route.steps[step].coordinateIndex] - walked, 0)
        let lifetime = Self.nowCueLifetime(remaining)
        await submit(maneuver(route.steps[step].spokenInstruction, .high, haptic: route.steps[step].kind.haptic,
                              expiresIn: lifetime, key: "step-\(step)-now-r1"))
    }

    // MARK: Wording

    private func announcement(for event: RouteProgressTracker.GuidanceEvent,
                              progress: RouteProgressTracker.Progress) -> AnnouncementEvent? {
        guard let route else { return nil }
        switch event {
        case let .prepare(step, distance):
            // stairs are a fall risk, so like a crossing they are said even with Important only, and wait out a
            // long start sentence
            let isStairs = route.steps[step].kind == .stairs
            return maneuver(prepareText(route.steps[step], in: distance), isStairs ? .high : .normal,
                            expiresIn: isStairs ? 15 : 8, key: "step-\(step)-prepare")
        case let .now(step):
            return maneuver(route.steps[step].spokenInstruction, .high, haptic: route.steps[step].kind.haptic,
                            expiresIn: Self.nowCueLifetime(progress.distanceToNextStep), key: "step-\(step)-now")
        case let .passedTurnConfirmation(step):
            return maneuver("Continue for \(spoken(progress.distanceToNextStep)).", .normal, expiresIn: 6,
                            key: "step-\(step)-confirmation")
        case let .missedTurn(step, distanceBack):
            // a reroute starts from the next precise fix when allowed; otherwise the way back is the guidance. Not
            // the turn itself: walking back reaches it from the other side, so its left and right are swapped.
            let text = if rerouteTask != nil || canRequestReroute {
                "You may have passed the turn. Finding a new route."
            } else if let direction = direction(to: route.coordinates[route.steps[step].coordinateIndex]) {
                "You may have passed the turn. It is \(direction.phrase), \(spoken(distanceBack)) away."
            } else {
                "You may have passed the turn. Turn around and walk back \(spoken(distanceBack))."
            }
            return maneuver(text, .high, haptic: .attention, expiresIn: 12, key: "step-\(step)-missed")
        case let .crossing(index):
            return maneuver(crossingText(routeCrossings[index]), .high, haptic: .attention, expiresIn: 8,
                            key: "crossing-\(index)")
        case .wrongWay:
            let text = pathSentence().map { "You're walking away from the route. \($0)" }
                ?? "You seem to be walking away from the route. Turn around."
            return maneuver(text, .high, haptic: .attention, expiresIn: 10, key: "wrong-way")
        case .offRoute:
            return maneuver(offRouteSpeech, .high, haptic: .attention, expiresIn: 10, key: "off-route")
        case .backOnRoute:
            return maneuver("Back on the route.", .normal, expiresIn: 6, key: "back-on-route")
        case .arrived:
            return arrivalAnnouncement()
        }
    }

    /// Says only what the map knows: a signal without `traffic_signals:sound` may still be audible.
    private func crossingText(_ crossing: RouteCrossing) -> String {
        if crossing.audibleSignal { return "Crosswalk ahead, with audible signal." }
        return switch crossing.control {
        case .signals: "Crosswalk ahead, with a traffic signal."
        case .marked: "Crosswalk ahead."
        case .unmarked: "Road crossing ahead, unmarked."
        case .unknown: "Road crossing ahead."
        }
    }

    private var offRouteSpeech: String {
        reroutesRemain
            ? "You're off the route. Finding a new route."
            : "You're off the route. Head back toward the path."
    }

    private func arrivalAnnouncement() -> AnnouncementEvent? {
        guard let route, let destination, let arrival = route.steps.last else { return nil }
        let name = destination.name
        // from the user's heading, since Valhalla's side assumes they arrive facing along the route
        let text = if let origin = directionOrigin,
                      GeoMath.distance(from: origin.coordinate, to: destination.coordinate)
                          >= Self.arrivalDirectionMinimum,
                      let direction = direction(to: destination.coordinate) {
            "Arriving at \(name). \(name) is \(direction.phrase)."
        } else {
            "Arriving at \(name). \(arrival.spokenInstruction)"
        }
        return maneuver(text, .high, haptic: .arrived, expiresIn: 15, key: "arrived")
    }

    /// Where the user is and how far off that may be, or nil when the latest fix is too rough or too old to say which
    /// way anything lies. Before the first fix the user is taken to be at the route's start, where the route was planned.
    private var directionOrigin: (coordinate: GeoCoordinate, accuracy: Double)? {
        guard let lastFix else { return route.map { ($0.coordinates[0], 0) } }
        guard lastFix.horizontalAccuracy <= Self.rerouteAccuracy,
              now().timeIntervalSince(lastFix.timestamp) <= Self.directionFixAge else { return nil }
        return (lastFix.coordinate, lastFix.horizontalAccuracy)
    }

    /// Which way `target` lies from the user, or nil while the heading is unknown, the latest fix is rough or old, or
    /// the target is within twice its accuracy.
    private func direction(to target: GeoCoordinate) -> RelativeDirection? {
        guard let origin = directionOrigin, let heading = headingEstimator.heading(at: now()),
              GeoMath.distance(from: origin.coordinate, to: target)
                  >= Self.directionAccuracyFactor * origin.accuracy else { return nil }
        let bearing = GeoMath.bearing(from: origin.coordinate, to: target)
        return RelativeDirection(.from(heading: heading.degrees, toAbsoluteBearing: bearing))
    }

    /// "The path is slightly left." or "Turn around, the path is behind you.", toward the route a little ahead of
    /// the user's progress, further with a rougher fix; nil when `direction(to:)` is.
    private func pathSentence() -> String? {
        guard let route, let progress, let origin = directionOrigin else { return nil }
        let lookAhead = max(Self.pathLookAhead, Self.directionAccuracyFactor * origin.accuracy)
        let ahead = min(route.totalDistance - progress.distanceRemaining + lookAhead, route.totalDistance)
        let target = GeoMath.coordinate(atDistance: ahead, along: route.coordinates,
                                        cumulativeDistances: route.cumulativeDistances)
        guard let direction = direction(to: target) else { return nil }
        return direction == .behind ? "Turn around, the path is behind you." : "The path is \(direction.phrase)."
    }

    /// The prepare for the step after departing, said with the path sentence: that replaces the first instruction,
    /// which often names this step, and the tracker counts a step this close as already prepared.
    private func firstTurnPrepare(on route: NavigationRoute) -> String {
        guard route.steps.count > 1 else { return "" }
        let step = route.steps[1]
        let position = route.cumulativeDistances[step.coordinateIndex]
        // the tracker warns of stairs itself on the first fix, so saying them here would say them twice; arriving has
        // its own announcement
        guard step.kind != .stairs, step.kind != .arrive, position <= RouteProgressTracker.prepareDistance,
              let progress else { return "" }
        let distance = max(position - (route.totalDistance - progress.distanceRemaining), 0)
        return " " + prepareText(step, in: distance)
    }

    /// What to do next, spoken after "Trip resumed.". Nothing within `nowDistance` of a turn, where the user may
    /// already have walked past it: the next fix's turn cue, confirmation or missed turn says the right thing.
    private func resumeAnnouncement() -> AnnouncementEvent? {
        guard let route, let progress, var tracker else { return nil }
        if progress.isOffRoute {
            return maneuver(offRouteSpeech, .high, haptic: .attention, expiresIn: 10, key: nil)
        }
        let index = progress.nextStepIndex
        let distance = progress.distanceToNextStep
        guard distance > RouteProgressTracker.nowDistance, missedTurnStep != index else { return nil }
        if distance <= RouteProgressTracker.prepareDistance {
            // said here, so the next fix doesn't say it again
            tracker.markPrepared(step: index)
            self.tracker = tracker
        }
        return maneuver(prepareText(route.steps[index], in: distance), .normal, expiresIn: 8, key: nil)
    }

    /// "In about 30 feet, turn left onto Ferst Drive." Stairs say which way they go instead of Valhalla's "Take the
    /// stairs", so the warning names the change of level.
    private func prepareText(_ step: RouteStep, in distance: Double) -> String {
        let action = step.kind == .stairs ? step.stairsPhrase + "." : Self.midSentence(step.spokenInstruction)
        return "In \(spoken(distance)), \(action)"
    }

    /// Keys carry the trip and route, so a quick restart or a reroute isn't deduplicated against the old one.
    private func maneuver(_ text: String, _ priority: AnnouncementPriority, haptic: HapticID? = nil,
                          expiresIn lifetime: TimeInterval, key: String?) -> AnnouncementEvent {
        let time = now()
        return AnnouncementEvent(category: .maneuver, priority: priority, text: text, haptic: haptic,
                                 source: .navigation, createdAt: time, expiresAt: time.addingTimeInterval(lifetime),
                                 dedupKey: key.map { "\(tripID)-v\(routeVersion)-\($0)" })
    }

    private func signalAnnouncement(_ text: String, _ priority: AnnouncementPriority,
                                    _ lifetime: TimeInterval) -> AnnouncementEvent {
        let time = now()
        return AnnouncementEvent(category: .system, priority: priority, text: text, source: .navigation,
                                 createdAt: time, expiresAt: time.addingTimeInterval(lifetime))
    }

    /// Voice commands speak the same text, so the engine's text dedup merges the two while button users still hear
    /// it.
    private func confirmation(_ text: String) -> AnnouncementEvent {
        AnnouncementEvent(category: .maneuver, priority: .high, text: text, source: .navigation, createdAt: now())
    }

    private func submit(_ event: AnnouncementEvent) async {
        await announcements.submit(event)
    }

    /// Long enough to reach the turn at a slow walk, so a cue stuck behind other speech still arrives in time.
    private static func nowCueLifetime(_ distance: Double) -> TimeInterval {
        min(max((distance + 5) / 1.3, 4), 15)
    }

    /// "about 80 metres" or "about 250 feet", in the user's units; read each time, so a change in Settings
    /// applies from the next cue.
    private func spoken(_ distance: Double) -> String {
        distances.formatter.spoken(distance)
    }

    private static func midSentence(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }
}
