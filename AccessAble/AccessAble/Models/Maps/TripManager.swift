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
    // not replayed: a question is for the trip it was asked on
    private nonisolated let questions = Broadcaster<ReportQuestion>()
    // replayed, so a map that opens mid-trip shows them; emptied when a trip starts or ends, so it never shows the
    // last trip's
    private nonisolated let shownReports = Broadcaster<[Report]>(replaysLatest: true)

    private let location: any LocationProvider
    private let routing: any RoutingService
    private let announcements: any AnnouncementEngineProtocol
    /// Nil where reports aren't available, so a trip doesn't listen for them.
    private let reports: (any ReportService)?
    /// The signed-in user, whose own reports don't reroute their trip: Route Blocked Ahead's Re-Route is their way
    /// round.
    private let currentUserID: @Sendable () async -> String?
    private let landmarks: any LandmarkObserving
    /// Read when a trip starts, not at launch: loading them parses a large bundled file.
    private let campusBuildings: @Sendable () -> [CampusBuilding]
    /// Read when a trip starts or reroutes, like `campusBuildings`.
    private let campusCrossings: @Sendable () -> [CampusCrossing]
    private let setTripTracking: @Sendable (Bool) async -> Void
    private let distances: DistanceSettings
    /// Writes nothing unless recording is on, and fix rows aren't even built then.
    private let recorder: TripRecorder?
    /// Where the trip in progress is kept for resuming after the app closes; nil keeps nothing.
    private let savedTrips: SavedTripStore?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    /// Bumped by `startTrip` and `endTrip`; a task from an older trip stops at its next check.
    private var generation = 0
    /// Bumped on each reroute, so a reroute answer or cue check for a replaced route is dropped.
    private var routeVersion = 0
    private var tripID = UUID()
    private var phase: TripPhase = .planning
    private var arrivedWhilePaused = false
    private enum ResumedStart {
        /// Waiting out `startDelay`.
        case delayed
        /// Said, but the first usable fix hasn't placed the user yet, so the way on comes when it does.
        case awaitingPlacement
    }
    /// A resumed trip's start announcement not yet said in full. Its turn cues wait for it, so the first is never
    /// said before the trip is.
    private var resumedStart: ResumedStart?
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
    private var reportTask: Task<Void, Never>?
    private var cueChecks: [Task<Void, Never>] = []

    /// Turn cues submitted and waiting for their delivery check, and those of them the engine has delivered.
    private var pendingCueIDs: Set<UUID> = []
    private var deliveredIDs: Set<UUID> = []
    private var missedTurnStep: Int?
    private var rerouteCount = 0
    private var lastRerouteRequest: Date?
    private var hasRerouted = false
    /// Where an asked-for reroute starts: the latest fix precise enough to start a route from, and when it was.
    private var lastPreciseFix: GeoCoordinate?
    private var lastPreciseFixAt: Date?
    /// The latest fix, however rough, for saying which way the path or the destination lies only when it is precise.
    private var lastFix: LocationSample?
    private var headingEstimator = HeadingEstimator()
    private var tripStartedAt = Date.distantPast
    private var lastGoodFixAt: Date?
    private var isSignalWeak = false
    /// The latest active reports near the route, without the user's own.
    private var nearbyReports: [Report] = []
    /// The latest snapshot as it came, the user's own reports included, for the map.
    private var latestReports: [Report] = []
    /// Reports rerouted around or warned of this trip; kept across reroutes and new subscriptions.
    private var actedOnReportIDs: Set<String> = []
    private var reportRerouteCount = 0
    /// Bumped on each subscription to reports, so a snapshot from a replaced one is dropped.
    private var reportSubscription = 0
    /// A report reroute kept the route, or failed, while paused: said on resuming, since the route still passes it.
    private var unavoidedReportOnResume = false
    /// Reports put to the user this trip, or walked too far past to ask; kept across reroutes.
    private var promptedReportIDs: Set<String> = []
    /// The question sent and not yet ended by the screen, and when it was sent.
    private var openQuestion: (reportID: String, askedAt: Date)?
    /// The nearest each report not yet asked about has been to a precise fix this trip, in metres.
    private var closestApproaches: [String: Double] = [:]
    /// When the last question was answered with a vote, and when the screen last didn't ask about each report.
    private var lastVoteAt: Date?
    private var notAskedAt: [String: Date] = [:]

    // the public routing server is shared and slow to recover; this spaces requests and bounds a bad walk
    private static let rerouteInterval: TimeInterval = 30
    // a reroute that came back shows the server is answering, and a user still lost shouldn't wait as long again
    private static let reroutedInterval: TimeInterval = 15
    private static let maximumReroutes = 5
    // seconds; a reroute from an older precise fix would start where the user was, not where they are
    private static let rerouteFixAge: TimeInterval = 10
    // reroutes for new reports ahead, apart from the off-route ones, so reports can't use up a lost user's
    private static let maximumReportReroutes = 2
    // waits before listening again after the report stream ends, on an error or signed out: longer each time in a
    // row, so a stream that keeps ending doesn't spin
    private static let reportRetryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(60)]
    // metres beyond the route's reach that reports are listened for
    private static let reportSearchMargin: Double = 250
    // metres; a report passed nearer than this is one the user could see, and the distance must then grow by the
    // margin, more than GPS jitter, before they have passed it
    private static let questionPassRadius: Double = 10
    private static let questionPassMargin: Double = 5
    // metres; a question nearer a turn or crossing than this would talk over its cue, so it waits, unless the user is
    // this far past the report by then and it is no longer "here"
    private static let questionManeuverClearance: Double = 30
    private static let questionGiveUpDistance: Double = 60
    // seconds from a vote to the next question: the rules allow one vote a minute
    private static let questionSpacing: TimeInterval = 60
    // seconds before a question the screen didn't ask is sent again, so it isn't sent on every fix
    private static let questionRetryDelay: TimeInterval = 10
    // seconds; a question the screen hasn't ended by then, such as one sent with the screen closed, counts as asked
    private static let questionReplyLimit: TimeInterval = 60
    private static let unavoidedReportSpeech =
        "Couldn't find a way around the reported obstacle. Keep following the current route carefully."
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
        reports: (any ReportService)? = nil,
        currentUserID: @escaping @Sendable () async -> String? = { nil },
        landmarks: any LandmarkObserving = PlaceholderLandmarkProvider(),
        campusBuildings: @escaping @Sendable () -> [CampusBuilding] = { CampusLandmarks.buildings },
        campusCrossings: @escaping @Sendable () -> [CampusCrossing] = { CampusCrossings.all },
        setTripTracking: @escaping @Sendable (Bool) async -> Void = { _ in },
        distances: DistanceSettings = DistanceSettings(units: .metres),
        recorder: TripRecorder? = nil,
        savedTrips: SavedTripStore? = nil,
        now: @escaping @Sendable () -> Date = { .now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.location = location
        self.routing = routing
        self.announcements = announcements
        self.reports = reports
        self.currentUserID = currentUserID
        self.landmarks = landmarks
        self.campusBuildings = campusBuildings
        self.campusCrossings = campusCrossings
        self.setTripTracking = setTripTracking
        self.distances = distances
        self.recorder = recorder
        self.savedTrips = savedTrips
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

    nonisolated func reportQuestions() -> AsyncStream<ReportQuestion> {
        questions.stream()
    }

    nonisolated func mapReports() -> AsyncStream<[Report]> {
        shownReports.stream()
    }

    func startTrip(route: NavigationRoute, destination: Destination, resumingAtStep: Int?) async {
        generation += 1
        let generation = generation
        cancelTasks()
        tripID = UUID()
        routeVersion = 0
        phase = .active
        arrivedWhilePaused = false
        resumedStart = resumingAtStep.map { _ in .delayed }
        self.destination = destination
        self.route = route
        routeCrossings = RouteCrossings.along(route, crossings: campusCrossings())
        let tracker = RouteProgressTracker(route: route, startedAt: now(),
                                           crossings: routeCrossings.map(\.distanceAlongRoute),
                                           resumingAtStep: resumingAtStep)
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
        lastPreciseFixAt = nil
        lastFix = nil
        headingEstimator = HeadingEstimator()
        tripStartedAt = now()
        lastGoodFixAt = nil
        isSignalWeak = false
        nearbyReports = []
        latestReports = []
        shownReports.send([])
        actedOnReportIDs = []
        reportRerouteCount = 0
        unavoidedReportOnResume = false
        promptedReportIDs = []
        closestApproaches = [:]
        openQuestion = nil
        lastVoteAt = nil
        notAskedAt = [:]
        routes.send(route)
        publish(at: now())
        saveTrip()
        recorder?.tripStarted(at: now())

        // subscribed before any await, so a fix or delivery can't slip past while this trip is set up
        let samples = location.locationSamples()
        let headings = location.headingSamples()
        let delivered = announcements.deliveredEvents()
        let sightings = landmarks.landmarkObservations()
        subscribeToReports(along: route, generation: generation)
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
        // "Trip resumed." says what to do next instead
        resumedStart = nil
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
        if self.generation == generation, phase == .active, unavoidedReportOnResume {
            unavoidedReportOnResume = false
            // off the route since, so it no longer passes the report
            if !needsReroute { await submit(unavoidedReportAnnouncement()) }
        }
        // a reroute that landed meanwhile has its own announcement, and this one is about the old route
        guard self.generation == generation, routeVersion == version, phase == .active, let guidance else { return }
        await submit(guidance)
    }

    func endTrip() async {
        guard phase != .planning else { return }
        generation += 1
        let generation = generation
        cancelTasks()
        savedTrips?.clear()
        phase = .planning
        tracker = nil
        progress = nil
        landmarkMatcher = nil
        routeCrossings = []
        route = nil
        destination = nil
        nearbyReports = []
        latestReports = []
        shownReports.send([])
        actedOnReportIDs = []
        unavoidedReportOnResume = false
        promptedReportIDs = []
        closestApproaches = [:]
        openQuestion = nil
        lastVoteAt = nil
        notAskedAt = [:]
        routes.send(nil)
        states.send(TripState(phase: .planning, updatedAt: now()))
        await setTripTracking(false)
        // a trip started meanwhile shouldn't hear that it ended, and has its own recording
        guard self.generation == generation else { return }
        await submit(confirmation("Trip ended."))
        recorder?.tripEnded()
    }

    private func cancelTasks() {
        for task in [trackingTask, deliveryTask, startTask, watchdogTask, rerouteTask, landmarkTask, headingTask,
                     reportTask] {
            task?.cancel()
        }
        for task in cueChecks {
            task.cancel()
        }
        landmarkTask = nil
        headingTask = nil
        reportTask = nil
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
                if phase == .active { pending.append((signalAnnouncement("Location signal is back.", .normal, 6), nil)) }
            }
        }
        // a late fix is no longer where they are
        if sample.horizontalAccuracy <= Self.rerouteAccuracy, sample.timestamp >= lastPreciseFixAt ?? .distantPast {
            lastPreciseFix = sample.coordinate
            lastPreciseFixAt = sample.timestamp
        }
        // a bearing from a NaN fix would trap when turned into a direction, and a late fix is no longer where they are
        if sample.coordinate.latitude.isFinite, sample.coordinate.longitude.isFinite,
           sample.horizontalAccuracy.isFinite, sample.timestamp >= lastFix?.timestamp ?? .distantPast {
            lastFix = sample
        }
        headingEstimator.update(with: sample)

        let previousStep = progress?.nextStepIndex
        let wasAwaitingPlacement = resumedStart == .awaitingPlacement
        let update = tracker.update(with: sample, emitsCues: phase == .active && resumedStart == nil)
        self.tracker = tracker
        progress = update.state
        record(sample, update, on: tracker.route)
        if update.events.contains(.arrived) {
            await arrive(at: sample.timestamp, generation: generation)
            return
        }
        if update.state.nextStepIndex != previousStep { saveTrip() }
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
        if wasAwaitingPlacement, tracker.placement != .awaitingFix {
            resumedStart = nil
            let guidance = resumedGuidance()
            if !guidance.isEmpty { pending.append((maneuver(guidance, .high, expiresIn: 15, key: "placed"), nil)) }
        }
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
        // after this fix's cues, so a question doesn't go ahead of them
        askAboutPassedReports(generation: generation)
        await considerReports(generation: generation)
    }

    private func handle(_ sample: HeadingSample, generation: Int) {
        guard self.generation == generation else { return }
        headingEstimator.update(with: sample)
    }

    private static func cueStep(of event: RouteProgressTracker.GuidanceEvent) -> Int? {
        if case let .now(step) = event { step } else { nil }
    }

    private func arrive(at time: Date, generation: Int) async {
        savedTrips?.clear()
        // the heading only words guidance, and the compass runs while it is subscribed
        for task in [watchdogTask, rerouteTask, deliveryTask, headingTask, reportTask] {
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
        recorder?.tripEnded()
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
        let instruction = progress.isOffRoute
            ? offRouteInstruction : RouteStep.withoutCompassDirection(step.instruction)
        states.send(TripState(
            phase: phase,
            destinationName: destination?.name,
            nextManeuver: Maneuver(kind: step.kind, instruction: instruction,
                                   coordinate: route.coordinates[step.coordinateIndex]),
            distanceToNextManeuver: progress.isOffRoute ? nil : progress.distanceToNextStep,
            distanceRemaining: progress.distanceRemaining,
            isOffRoute: progress.isOffRoute,
            hasArrived: phase == .arrived || arrivedWhilePaused,
            updatedAt: time
        ))
    }

    /// Keeps the route being followed and how far along its steps the user is, for resuming after the app closes.
    private func saveTrip() {
        guard let savedTrips, let route, let destination, let progress else { return }
        savedTrips.save(SavedTrip(tripID: tripID, route: route, routeSource: route.source,
                                  destination: destination, passedStepCount: progress.nextStepIndex,
                                  startedAt: tripStartedAt, savedAt: now()))
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
        let along = route.totalDistance - progress.distanceRemaining
        recorder?.record(sighting: sighting, progress: along, at: now())
        let event = matcher.match(sighting, progress: along, remaining: progress.distanceRemaining)
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

    // MARK: Community reports

    /// Listens for reports near `route` until the trip ends or the route changes, and again after a wait whenever the
    /// stream ends.
    private func subscribeToReports(along route: NavigationRoute, generation: Int) {
        reportTask?.cancel()
        reportTask = nil
        guard let reports else { return }
        reportSubscription += 1
        let subscription = reportSubscription
        // every point of the route is within half its length, along it, of its middle
        let center = GeoMath.coordinate(atDistance: route.totalDistance / 2, along: route.coordinates,
                                        cumulativeDistances: route.cumulativeDistances)
        let radius = route.totalDistance / 2 + Self.reportSearchMargin
        reportTask = Task { [currentUserID] in
            var retries = 0
            // an injected sleep may return rather than throw once cancelled
            while !Task.isCancelled {
                for await snapshot in reports.reportChanges(near: center, radius: radius) {
                    retries = 0
                    let userID = await currentUserID()
                    await self.receive(snapshot, userID: userID, subscription: subscription, generation: generation)
                }
                guard !Task.isCancelled else { return }
                let delay = Self.reportRetryDelays[min(retries, Self.reportRetryDelays.count - 1)]
                retries += 1
                log.notice("Report stream ended; listening again in \(String(describing: delay), privacy: .public)")
                do { try await self.sleep(delay) } catch { return }
            }
        }
    }

    private func receive(_ snapshot: [Report], userID: String?, subscription: Int, generation: Int) async {
        guard self.generation == generation, subscription == reportSubscription else { return }
        latestReports = snapshot
        nearbyReports = snapshot.filter { $0.reporterID != userID }
        publishMapReports()
        await considerReports(generation: generation)
    }

    /// The active reports near the route for the map, the user's own included: they want to see what they reported.
    /// Near is within the corridor the route summary counts avoided reports in, so the map shows those it mentions.
    private func publishMapReports() {
        guard let route else { return }
        let time = now()
        shownReports.send(ReportExclusions.reports(
            latestReports.filter { $0.expiresAt > time },
            within: ReportAwareRoutingService.avoidanceCorridor, of: route
        ))
    }

    /// Reroutes around reports the route ahead passes but wasn't planned around, or warns of them where a reroute
    /// can't help. A report not acted on stays a candidate, so one put off (paused, off route, a weak signal, a reroute
    /// in flight or too soon after the last) is weighed again on the next fix or snapshot.
    private func considerReports(generation: Int) async {
        guard self.generation == generation, phase == .active, !needsReroute, let route, let progress else { return }
        let walked = route.totalDistance - progress.distanceRemaining
        let time = now()
        // warned of when the route was planned
        let planned = Set(route.unavoidedReports.map(\.id))
        var nearUser: [Report] = []
        var nearEnd: [Report] = []
        var avoidable: [Report] = []
        for report in nearbyReports
        where report.expiresAt > time && !actedOnReportIDs.contains(report.id) && !planned.contains(report.id) {
            guard let along = ReportExclusions.distanceAlong(route, passing: report, from: walked) else { continue }
            // the routing drops a report this near either end first, so a new route would pass it anyway
            if along - walked < ReportAwareRoutingService.endpointClearance {
                nearUser.append(report)
            } else if route.totalDistance - along < ReportAwareRoutingService.endpointClearance {
                nearEnd.append(report)
            } else {
                avoidable.append(report)
            }
        }
        var warned = nearUser + nearEnd
        let warning = nearUser.isEmpty ? "New obstacle reported ahead." : "New obstacle reported just ahead."
        if !avoidable.isEmpty, rerouteTask == nil {
            if reportRerouteCount >= Self.maximumReportReroutes {
                warned += avoidable
            } else if !isSignalWeak, let origin = recentPreciseFix, rerouteSpacingElapsed {
                actedOnReportIDs.formUnion((avoidable + warned).map(\.id))
                // said by the reroute's task before it asks, so its answer can't come first; and in flight from here,
                // so a fix or snapshot meanwhile waits for it
                // the reroute's own line covers those near the end
                var announcements = nearUser.first.map { near in
                    [maneuver(warning, .high, haptic: .attention, expiresIn: 10, key: "report-warning-\(near.id)")]
                } ?? []
                announcements.append(maneuver("New obstacle reported ahead. Finding a new route.", .high,
                                              haptic: .attention, expiresIn: 15,
                                              key: "report-reroute-\(avoidable[0].id)"))
                // the near ones too, so a new route that passes them warns of them
                requestReroute(from: origin, generation: generation, requested: true, avoiding: avoidable,
                               alsoAvoiding: warned, announcing: announcements)
                return
            }
        }
        guard let first = warned.first else { return }
        actedOnReportIDs.formUnion(warned.map(\.id))
        await submit(maneuver(warning, .high, haptic: .attention, expiresIn: 10, key: "report-warning-\(first.id)"))
    }

    /// The screen has ended the question about `reportID`. One it didn't put to the user may be asked again after
    /// `questionRetryDelay`; after a vote, the next question waits `questionSpacing`.
    func reportQuestionEnded(_ reportID: String, outcome: ReportQuestionOutcome) async {
        endQuestion(reportID, outcome: outcome)
    }

    private func endQuestion(_ reportID: String, outcome: ReportQuestionOutcome) {
        // a vote still counts once the question has ended, as a button pressed as it closed does
        if outcome == .voted {
            promptedReportIDs.insert(reportID)
            lastVoteAt = now()
        }
        guard openQuestion?.reportID == reportID else { return }
        openQuestion = nil
        switch outcome {
        case .notAsked:
            notAskedAt[reportID] = now()
        case .unanswered:
            promptedReportIDs.insert(reportID)
        case .voted:
            break
        }
    }

    /// Asks about a report the user has just walked past: their nearest approach to it was within
    /// `questionPassRadius`, and they are now `questionPassMargin` further away. Only from a recent precise fix, while
    /// following the route, and not near a turn or crossing; one question at a time, `questionSpacing` after the
    /// last vote, and once a report a trip.
    private func askAboutPassedReports(generation: Int) {
        guard self.generation == generation, phase == .active, !needsReroute, rerouteTask == nil,
              let route, let progress, let fix = recentPreciseFix else { return }
        let time = now()
        let walked = route.totalDistance - progress.distanceRemaining
        let nearManeuver = progress.distanceToNextStep < Self.questionManeuverClearance
            || routeCrossings.contains { (0..<Self.questionManeuverClearance).contains($0.distanceAlongRoute - walked) }
        if let open = openQuestion, time.timeIntervalSince(open.askedAt) >= Self.questionReplyLimit {
            log.notice("A report question wasn't ended by the screen; counting it as asked")
            endQuestion(open.reportID, outcome: .unanswered)
        }
        let spaced = lastVoteAt.map { time.timeIntervalSince($0) >= Self.questionSpacing } ?? true
        var canAsk = openQuestion == nil && spaced && !nearManeuver
        for report in nearbyReports
        where report.expiresAt > time && !promptedReportIDs.contains(report.id) && openQuestion?.reportID != report.id
            && notAskedAt[report.id].map({ time.timeIntervalSince($0) >= Self.questionRetryDelay }) ?? true {
            let distance = report.distance(from: fix)
            let closest = min(closestApproaches[report.id] ?? .infinity, distance)
            closestApproaches[report.id] = closest
            guard closest < Self.questionPassRadius, distance >= closest + Self.questionPassMargin else { continue }
            if distance > Self.questionGiveUpDistance {
                promptedReportIDs.insert(report.id)
                closestApproaches[report.id] = nil
                continue
            }
            guard canAsk else { continue }
            canAsk = false
            openQuestion = (report.id, time)
            questions.send(ReportQuestion(report: report, askedAt: time))
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
        return rerouteSpacingElapsed
    }

    /// `lastPreciseFix` while it is recent enough to start a reroute from.
    private var recentPreciseFix: GeoCoordinate? {
        guard let lastPreciseFixAt, now().timeIntervalSince(lastPreciseFixAt) <= Self.rerouteFixAge else { return nil }
        return lastPreciseFix
    }

    /// Long enough since the last request, whatever it was for, for the public routing server.
    private var rerouteSpacingElapsed: Bool {
        let interval = hasRerouted ? Self.reroutedInterval : Self.rerouteInterval
        return lastRerouteRequest.map { now().timeIntervalSince($0) >= interval } ?? true
    }

    /// A new route from where the user is now, asked for by the user (Route Blocked Ahead's
    /// "find another way") rather than because they left the route. The new route avoids the obstacle only once it
    /// has been reported, and says so when it can't.
    func reroute() async {
        guard phase == .active || phase == .paused else { return }
        // with a weak signal the last precise fix is old, and the user has walked on from it
        guard let origin = recentPreciseFix, !isSignalWeak else {
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

    /// - Parameters:
    ///   - requested: Asked for by the user or for new reports, so it lands even while still on the route.
    ///   - triggers: New reports ahead to route around. A reroute for them counts apart from the off-route ones.
    ///   - others: Reports the route should avoid if it can, without being for them.
    ///   - announcements: Said, in order, before the request goes out.
    private func requestReroute(from origin: GeoCoordinate, generation: Int, requested: Bool = false,
                                avoiding triggers: [Report] = [], alsoAvoiding others: [Report] = [],
                                announcing announcements: [AnnouncementEvent] = []) {
        guard let destination else { return }
        if triggers.isEmpty { rerouteCount += 1 } else { reportRerouteCount += 1 }
        lastRerouteRequest = now()
        let version = routeVersion
        rerouteTask = Task { [routing] in
            // not after a pause that came first
            for announcement in announcements where !Task.isCancelled && self.phase == .active {
                await self.submit(announcement)
            }
            let result: Result<NavigationRoute, any Error>
            do {
                result = .success(try await routing.route(from: origin, to: destination.coordinate,
                                                          options: RouteOptions(reports: triggers + others)))
            } catch {
                result = .failure(error)
            }
            await self.finishReroute(result, generation: generation, version: version, requested: requested,
                                     triggers: triggers)
        }
    }

    private func finishReroute(_ result: Result<NavigationRoute, any Error>, generation: Int, version: Int,
                               requested: Bool, triggers: [Report]) async {
        guard self.generation == generation, routeVersion == version else { return }
        rerouteTask = nil
        // back on the route, or arrived, since the request went out
        guard phase == .active || phase == .paused, !arrivedWhilePaused, needsReroute || requested else { return }
        switch result {
        case .success(let newRoute):
            // passing every report it was for, it is no better than the route the user is already following
            let unavoided = Set(newRoute.unavoidedReports.map(\.id))
            if !triggers.isEmpty, !needsReroute, triggers.allSatisfy({ unavoided.contains($0.id) }) {
                guard phase == .active else {
                    unavoidedReportOnResume = true
                    return
                }
                await submit(unavoidedReportAnnouncement())
                return
            }
            unavoidedReportOnResume = false
            let sourceChange = Self.sourceChange(from: route, to: newRoute)
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
            saveTrip()
            routes.send(newRoute)
            publish(at: now())
            publishMapReports()
            subscribeToReports(along: newRoute, generation: generation)
            guard phase == .active else { return }
            await submit(maneuver("New route. " + Self.reportWarning(on: newRoute) + sourceChange
                                      + departure(on: newRoute), .high, expiresIn: 15, key: "reroute"))
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            log.error("Reroute failed: \(error.localizedDescription, privacy: .public)")
            if requested, !needsReroute, !triggers.isEmpty {
                // still on the route that passes it
                guard phase == .active else {
                    unavoidedReportOnResume = true
                    return
                }
                await submit(unavoidedReportAnnouncement())
                return
            }
            guard phase == .active else { return }
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

    private func unavoidedReportAnnouncement() -> AnnouncementEvent {
        maneuver(Self.unavoidedReportSpeech, .high, haptic: .attention, expiresIn: 10, key: "report-unavoided")
    }

    // MARK: Timed announcements

    private func announceStart(generation: Int) async {
        do { try await sleep(Self.startDelay) } catch { return }
        guard self.generation == generation, phase == .active, let route, let destination else { return }
        guard resumedStart == nil else {
            await announceResumedStart(on: route, to: destination)
            return
        }
        let text = "Starting directions to \(destination.name), \(spoken(route.totalDistance)). "
            + Self.reportWarning(on: route) + (route.source == .appleMaps ? RouteSource.backupNotice + " " : "")
            + departure(on: route)
        await submit(maneuver(text, .high, expiresIn: 15, key: "start"))
    }

    /// "Resuming directions to Library, about 160 metres.", then the way on from where the first usable fix placed
    /// the user. Before that fix, without the distance, and the way on comes with it.
    private func announceResumedStart(on route: NavigationRoute, to destination: Destination) async {
        let placement = tracker?.placement
        let remaining = placement == .onRoute ? progress.map { ", " + spoken($0.distanceRemaining) } : nil
        var text = "Resuming directions to \(destination.name)\(remaining ?? ""). " + Self.reportWarning(on: route)
            + (route.source == .appleMaps ? RouteSource.backupNotice + " " : "")
        if placement == .awaitingFix {
            resumedStart = .awaitingPlacement
        } else {
            resumedStart = nil
            text += resumedGuidance()
        }
        await submit(maneuver(text.trimmingCharacters(in: .whitespaces), .high, expiresIn: 15, key: "start"))
    }

    /// Which way the path is and the next step, from where a resumed trip's first usable fix placed the user; nothing
    /// for one it found far from the route, whom the off-route rules guide.
    private func resumedGuidance() -> String {
        guard tracker?.placement == .onRoute else { return "" }
        return [pathSentence(), nextStepPrepare()].compactMap { $0 }.joined(separator: " ")
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
            await submit(signalAnnouncement("Location signal is weak. Directions may be delayed.", .high, 10))
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
        } else if arrival.spokenInstruction.hasPrefix("You have arrived") {
            // Valhalla's generic arrival, which would say arriving twice
            "You have arrived at \(name)."
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

    /// Said before setting off on a route that passes reports it couldn't avoid.
    private static func reportWarning(on route: NavigationRoute) -> String {
        route.unavoidedReports.isEmpty ? "" : ReportExclusions.warning + " "
    }

    /// Said on a new route from a different service than the one before: a backup that may include stairs, or the
    /// accessible directions again.
    private static func sourceChange(from previous: NavigationRoute?, to route: NavigationRoute) -> String {
        guard let previous, previous.source != route.source else { return "" }
        return switch route.source {
        case .appleMaps: RouteSource.backupNotice + " "
        case .valhalla: "Back to accessible directions. "
        }
    }

    /// How to set off, at the start and on a new route: which way the path is, then the first turn when it is near.
    ///
    /// Never Valhalla's first instruction, whose compass direction ("Walk north on Ferst Drive.") a blind user can't
    /// act on. With the heading unknown it names the street to follow instead, and says that the wrong way would be
    /// caught: the tracker warns of walking away from the start, and off route covers the rest.
    private func departure(on route: NavigationRoute) -> String {
        let setOff = pathSentence() ?? {
            let follow = RouteStep.withoutCompassDirection(route.steps[0].instruction)
            return (follow.hasSuffix(".") ? follow : follow + ".") + " You'll be warned if it's the wrong way."
        }()
        return setOff + firstTurnPrepare(on: route)
    }

    /// The prepare for the step after departing, said after setting off: that replaces the first instruction, which
    /// often names this step, and the tracker counts a step this close as already prepared.
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

    /// What to do next, spoken after "Trip resumed.".
    private func resumeAnnouncement() -> AnnouncementEvent? {
        guard let progress else { return nil }
        if progress.isOffRoute {
            return maneuver(offRouteSpeech, .high, haptic: .attention, expiresIn: 10, key: nil)
        }
        return nextStepPrepare().map { maneuver($0, .normal, expiresIn: 8, key: nil) }
    }

    /// The next step's prepare, for picking up guidance mid-route. Nothing within `nowDistance` of it, where the user
    /// may already have walked past it: the next fix's turn cue, confirmation or missed turn says the right thing.
    private func nextStepPrepare() -> String? {
        guard let route, let progress, var tracker else { return nil }
        let index = progress.nextStepIndex
        let distance = progress.distanceToNextStep
        guard distance > RouteProgressTracker.nowDistance, missedTurnStep != index else { return nil }
        if distance <= RouteProgressTracker.prepareDistance {
            // said here, so the next fix doesn't say it again
            tracker.markPrepared(step: index)
            self.tracker = tracker
        }
        return prepareText(route.steps[index], in: distance)
    }

    /// "In about 30 feet, turn left onto Ferst Drive." Stairs say which way they go instead of Valhalla's "Take the
    /// stairs", so the warning names the change of level.
    private func prepareText(_ step: RouteStep, in distance: Double) -> String {
        let action = switch step.kind {
        case .stairs: step.stairsPhrase + "."
        // Valhalla's generic arrival is past tense; its "on the left" kind is kept, since it says where to look
        case .arrive where step.spokenInstruction.hasPrefix("You have arrived"): "you'll reach \(destination?.name ?? "your destination")."
        default: Self.midSentence(step.spokenInstruction)
        }
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
        recorder?.record(announcement: event.text, at: event.createdAt)
        await announcements.submit(event)
    }

    private func record(_ sample: LocationSample, _ update: RouteProgressTracker.Update, on route: NavigationRoute) {
        guard let recorder, recorder.isRecording else { return }
        recorder.record(TripRecorder.Fix(
            sample: sample, heading: headingEstimator.heading(at: now()),
            compassAccuracy: headingEstimator.compassAccuracy,
            progress: route.totalDistance - update.state.distanceRemaining, sideOffset: update.sideOffset,
            nextStepIndex: update.state.nextStepIndex, isOffRoute: update.state.isOffRoute, events: update.events
        ))
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
