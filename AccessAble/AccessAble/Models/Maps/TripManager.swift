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
    private let setBackgroundTracking: @Sendable (Bool) async -> Void
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
    private var progress: RouteProgressTracker.Progress?

    private var trackingTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var rerouteTask: Task<Void, Never>?
    private var cueChecks: [Task<Void, Never>] = []

    /// Turn cues submitted and waiting for their delivery check, and those of them the engine has delivered.
    private var pendingCueIDs: Set<UUID> = []
    private var deliveredIDs: Set<UUID> = []
    private var missedTurnStep: Int?
    private var rerouteCount = 0
    private var lastRerouteRequest: Date?
    private var tripStartedAt = Date.distantPast
    private var lastGoodFixAt: Date?
    private var isSignalWeak = false

    // the public routing server is shared and slow to recover; this spaces requests and bounds a bad walk
    private static let rerouteInterval: TimeInterval = 30
    private static let maximumReroutes = 5
    // a new route from a rough fix would start on the wrong side of the street
    private static let rerouteAccuracy: Double = 20
    // VoiceOver moves focus when the Start button disappears; speaking at once would be cut off by that
    private static let startDelay: Duration = .milliseconds(750)
    private static let watchdogInterval: Duration = .seconds(5)
    // the first fixes of a trip are often slow, so don't warn before then
    private static let watchdogGrace: TimeInterval = 5
    // guidance from fixes rougher than this is unreliable
    private static let weakSignalAccuracy: Double = 30
    private static let weakSignalWait: TimeInterval = 10

    init(
        location: any LocationProvider,
        routing: any RoutingService,
        announcements: any AnnouncementEngineProtocol,
        setBackgroundTracking: @escaping @Sendable (Bool) async -> Void = { _ in },
        now: @escaping @Sendable () -> Date = { .now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.location = location
        self.routing = routing
        self.announcements = announcements
        self.setBackgroundTracking = setBackgroundTracking
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
        let tracker = RouteProgressTracker(route: route, startedAt: now())
        self.tracker = tracker
        progress = tracker.state
        pendingCueIDs = []
        deliveredIDs = []
        missedTurnStep = nil
        rerouteCount = 0
        lastRerouteRequest = nil
        tripStartedAt = now()
        lastGoodFixAt = nil
        isSignalWeak = false
        routes.send(route)
        publish(at: now())

        // subscribed before any await, so a fix or delivery can't slip past while this trip is set up
        let samples = location.locationSamples()
        let delivered = announcements.deliveredEvents()
        deliveryTask = Task {
            for await event in delivered { self.markDelivered(event.id, generation: generation) }
        }
        trackingTask = Task {
            for await sample in samples { await self.handle(sample, generation: generation) }
        }
        startTask = Task { await self.announceStart(generation: generation) }
        watchdogTask = Task { await self.watchSignal(generation: generation) }
        await setBackgroundTracking(true)
        // an end that ran during the await may have switched it off before this switched it on
        if self.generation != generation, phase == .planning {
            await setBackgroundTracking(false)
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
        route = nil
        destination = nil
        routes.send(nil)
        states.send(TripState(phase: .planning, updatedAt: now()))
        await setBackgroundTracking(false)
        // a trip started meanwhile shouldn't hear that it ended
        guard self.generation == generation else { return }
        await submit(confirmation("Trip ended."))
    }

    private func cancelTasks() {
        for task in [trackingTask, deliveryTask, startTask, watchdogTask, rerouteTask] {
            task?.cancel()
        }
        for task in cueChecks {
            task.cancel()
        }
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
        // decided from the fixes before this one, so a reroute starts from the fix after the cue
        let rerouteOrigin = wantsReroute && sample.horizontalAccuracy <= Self.rerouteAccuracy
            ? sample.coordinate : nil

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
        // this fix may have brought the user back
        if let rerouteOrigin, needsReroute { requestReroute(from: rerouteOrigin, generation: generation) }

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

    private static func cueStep(of event: RouteProgressTracker.GuidanceEvent) -> Int? {
        if case let .now(step) = event { step } else { nil }
    }

    private func arrive(at time: Date, generation: Int) async {
        for task in [watchdogTask, rerouteTask, deliveryTask] {
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
        await setBackgroundTracking(false)
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
        return lastRerouteRequest.map { now().timeIntervalSince($0) >= Self.rerouteInterval } ?? true
    }

    private func requestReroute(from origin: GeoCoordinate, generation: Int) {
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
            await self.finishReroute(result, generation: generation, version: version)
        }
    }

    private func finishReroute(_ result: Result<NavigationRoute, any Error>, generation: Int, version: Int) async {
        guard self.generation == generation, routeVersion == version else { return }
        rerouteTask = nil
        // back on the route, or arrived, since the request went out
        guard phase == .active || phase == .paused, !arrivedWhilePaused, needsReroute else { return }
        switch result {
        case .success(let newRoute):
            routeVersion += 1
            route = newRoute
            let tracker = RouteProgressTracker(route: newRoute, startedAt: now())
            self.tracker = tracker
            progress = tracker.state
            missedTurnStep = nil
            routes.send(newRoute)
            publish(at: now())
            guard phase == .active, let first = newRoute.steps.first else { return }
            await submit(maneuver("New route. \(first.spokenInstruction)", .high, expiresIn: 15, key: "reroute"))
        case .failure(let error):
            guard !(error is CancellationError), phase == .active else { return }
            log.error("Reroute failed: \(error.localizedDescription, privacy: .public)")
            let text = rerouteCount < Self.maximumReroutes
                ? "Couldn't get a new route. Walk back the way you came."
                : "Off route. End the trip and choose your destination again."
            await submit(maneuver(text, .high, haptic: .attention, expiresIn: 10, key: "reroute-failed"))
        }
    }

    // MARK: Timed announcements

    private func announceStart(generation: Int) async {
        do { try await sleep(Self.startDelay) } catch { return }
        guard self.generation == generation, phase == .active, let route, let destination,
              let first = route.steps.first else { return }
        let text = "Starting directions to \(destination.name), \(Self.metres(route.totalDistance)). "
            + first.spokenInstruction
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
            let text = "In \(Self.metres(distance)), \(Self.midSentence(route.steps[step].spokenInstruction))"
            return maneuver(text, .normal, expiresIn: 8, key: "step-\(step)-prepare")
        case let .now(step):
            return maneuver(route.steps[step].spokenInstruction, .high, haptic: route.steps[step].kind.haptic,
                            expiresIn: Self.nowCueLifetime(progress.distanceToNextStep), key: "step-\(step)-now")
        case let .passedTurnConfirmation(step):
            return maneuver("Continue for \(Self.metres(progress.distanceToNextStep)).", .normal, expiresIn: 6,
                            key: "step-\(step)-confirmation")
        case let .missedTurn(step, distanceBack):
            // a reroute starts from the next precise fix when allowed; otherwise the way back is the guidance
            let text = rerouteTask != nil || canRequestReroute
                ? "You may have passed the turn. Finding a new route."
                : "You may have passed the turn. Turn around and walk back \(Self.metres(distanceBack)), then "
                    + Self.midSentence(route.steps[step].spokenInstruction)
            return maneuver(text, .high, haptic: .attention, expiresIn: 12, key: "step-\(step)-missed")
        case .wrongWay:
            return maneuver("You seem to be walking away from the route. Turn around.", .high, haptic: .attention,
                            expiresIn: 10, key: "wrong-way")
        case .offRoute:
            return maneuver(offRouteSpeech, .high, haptic: .attention, expiresIn: 10, key: "off-route")
        case .backOnRoute:
            return maneuver("Back on the route.", .normal, expiresIn: 6, key: "back-on-route")
        case .arrived:
            return arrivalAnnouncement()
        }
    }

    private var offRouteSpeech: String {
        reroutesRemain
            ? "You're off the route. Finding a new route."
            : "You're off the route. Head back toward the path."
    }

    private func arrivalAnnouncement() -> AnnouncementEvent? {
        guard let route, let destination, let arrival = route.steps.last else { return nil }
        return maneuver("Arriving at \(destination.name). \(arrival.spokenInstruction)", .high, haptic: .arrived,
                        expiresIn: 15, key: "arrived")
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
        let text = "In \(Self.metres(distance)), \(Self.midSentence(route.steps[index].spokenInstruction))"
        return maneuver(text, .normal, expiresIn: 8, key: nil)
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

    /// Rounded to 10 m, like the map's route summary: finer is noise.
    private static func metres(_ distance: Double) -> String {
        "about \(max(10, Int((distance / 10).rounded()) * 10)) metres"
    }

    private static func midSentence(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }
}
