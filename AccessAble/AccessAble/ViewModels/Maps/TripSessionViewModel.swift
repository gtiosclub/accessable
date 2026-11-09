import Foundation
import Observation

/// Owner: Maps (2.x) + Interaction (3.x). State for the redesigned trip screen.
///
/// With services (the app), it walks a real trip: a Valhalla route from where the user is to
/// the chosen place (through `TripViewModel`), turn-by-turn from `TripManager`, obstacle
/// warnings from the camera pipeline, and the Route Blocked Ahead page when the path stays
/// blocked with no way round. Every bar on screen is something the announcement engine
/// delivered, so what is shown is what was said.
///
/// Without services (tests, previews) it is front end only: announcements are whatever is
/// added, and voice commands show their sample responses.
@MainActor
@Observable
final class TripSessionViewModel {
    let plan: TripPlan
    private(set) var announcements: [TripAnnouncement]
    var isMicMuted = true
    private(set) var isPaused = false
    private(set) var isRouteBlocked = false
    var showsMap = false

    /// How many announcements stay on screen; older ones scroll off.
    static let visibleAnnouncementLimit = 3

    /// Real directions; nil when front end only.
    let directions: TripViewModel?

    @ObservationIgnored private let services: AppServices?
    @ObservationIgnored private let warningLifetime: Duration
    @ObservationIgnored private let infoLifetime: Duration
    @ObservationIgnored private var blockDetector = RouteBlockDetector()
    @ObservationIgnored private var hasSetDestination = false

    /// - Parameters:
    ///   - services: The app's services, for a real trip; nil for front end only.
    ///   - warningLifetime, infoLifetime: How long a red or blue bar stays before it fades.
    init(
        plan: TripPlan,
        services: AppServices? = nil,
        announcements: [TripAnnouncement] = [],
        warningLifetime: Duration = .seconds(8),
        infoLifetime: Duration = .seconds(12)
    ) {
        self.plan = plan
        self.services = services
        self.directions = services.map { TripViewModel(services: $0) }
        self.warningLifetime = warningLifetime
        self.infoLifetime = infoLifetime
        self.announcements = []
        for announcement in announcements.suffix(Self.visibleAnnouncementLimit) { add(announcement) }
    }

    var latestAnnouncement: TripAnnouncement? { announcements.last }

    /// True when the announcement engine speaks what is shown (a real trip), so the screen
    /// mustn't post the same words to VoiceOver again: the engine already speaks through
    /// VoiceOver when it is running.
    var isSpokenByEngine: Bool { services != nil }

    var destinationName: String { plan.place.name }

    /// One line on where directions stand, or nil while walking normally.
    var directionsStatus: String? {
        guard let directions else { return nil }
        if directions.needsLocationAccess { return "Directions need Precise Location. Turn it on in Settings." }
        if let error = directions.routeErrorMessage { return error }
        switch directions.tripState.phase {
        case .planning: return "Finding a walking route to \(destinationName)…"
        case .arrived: return "You have arrived at \(destinationName)."
        case .active, .paused: return nil
        }
    }

    func add(_ announcement: TripAnnouncement) {
        announcements.append(announcement)
        if announcements.count > Self.visibleAnnouncementLimit {
            announcements.removeFirst(announcements.count - Self.visibleAnnouncementLimit)
        }
        // Bars fade away rather than pile up: a warning is stale sooner than a direction.
        let lifetime = announcement.kind == .warning ? warningLifetime : infoLifetime
        Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            self?.announcements.removeAll { $0.id == announcement.id }
        }
    }

    // MARK: - Running a real trip

    /// Runs the trip while the screen is open: holds the camera (so warnings keep coming in
    /// map view), finds the route and starts it, and shows what is announced. Returns when
    /// the calling task is cancelled. The trip itself carries on in `TripManager` until
    /// `exit()`, so opening Settings from the paused card doesn't end it.
    func run() async {
        guard let services, let directions else { return }
        if !hasSetDestination {
            hasSetDestination = true
            directions.setDestination(Destination(
                name: plan.place.name,
                coordinate: GeoCoordinate(latitude: plan.place.latitude, longitude: plan.place.longitude),
                address: plan.place.address
            ))
            if let origin = plan.origin {
                await say("Directions start from where you are now, not from \(origin.name).", category: .system)
            }
        }
        let holdsCamera = (try? await services.scene.start()) != nil
        await withDiscardingTaskGroup { group in
            group.addTask { await directions.start() }
            group.addTask { await self.startWhenRouteIsReady() }
            group.addTask { await self.showAnnouncements(from: services.announcements) }
            group.addTask { await self.watchForBlockedPath(services.scene) }
        }
        if holdsCamera { await services.scene.stop() }
    }

    /// Starts walking as soon as a route is ready, and again after a re-route.
    private func startWhenRouteIsReady() async {
        guard let directions else { return }
        for await canStart in Observations({ directions.canStartTrip }) where canStart {
            await directions.startTrip()
        }
    }

    private func showAnnouncements(from engine: any AnnouncementEngineProtocol) async {
        for await event in engine.deliveredEvents() {
            guard !event.text.isEmpty else { continue }
            add(TripAnnouncement(text: event.text, kind: event.category == .hazard ? .warning : .info))
        }
    }

    private func watchForBlockedPath(_ scene: any SceneObservationProviding) async {
        // The path assessment comes from the camera pipeline's occupancy map; the sample
        // scene (Simulator, previews) has none.
        guard let analyzer = scene as? ARSceneAnalyzer else { return }
        for await observation in analyzer.observations() {
            let time = observation.timestamp.timeIntervalSinceReferenceDate
            guard !isPaused, !isRouteBlocked else {
                blockDetector.dismiss(at: time)
                continue
            }
            if blockDetector.update(analyzer.perception.diagnostics.path, at: time) {
                isRouteBlocked = true
                await say("Route blocked ahead. Something is in the way with no way round.", category: .hazard)
            }
        }
    }

    // MARK: - Commands

    /// Runs a command from the Voice Commands sheet. Returns false for commands that open
    /// other UI.
    @discardableResult
    func run(_ command: VoiceCommandHint) -> Bool {
        switch command {
        case .pauseTrip:
            pause()
            return true
        case .callHelp:
            return false
        default:
            guard let services else {
                guard let response = command.sampleResponse else { return false }
                add(response)
                return true
            }
            Task { await self.perform(command, with: services) }
            return true
        }
    }

    /// The real command. What it says comes back from the engine as a bar.
    private func perform(_ command: VoiceCommandHint, with services: AppServices) async {
        let text: String
        switch command {
        case .repeatWarning:
            await services.announcements.repeatLast()
            return
        case .describeSurroundings:
            text = await services.sceneDescriber.describeCurrentScene()
        case .describeLocation:
            text = await services.locationContext.currentLocationDescription()
                ?? "Describing your location isn't available yet."
        case .pauseTrip, .callHelp:
            return
        }
        await say(text, category: .ambient)
    }

    private func say(_ text: String, category: AnnouncementCategory) async {
        guard let services else {
            add(TripAnnouncement(text: text, kind: category == .hazard ? .warning : .info))
            return
        }
        await services.announcements.submit(AnnouncementEvent(
            category: category, priority: .high, text: text, source: .userInteraction
        ))
    }

    // MARK: - Pause, blocked route, exit

    func pause() {
        answerBlockedRoute()
        isPaused = true
        Task { await directions?.togglePauseIfActive() }
    }

    func resume() {
        answerBlockedRoute()
        isPaused = false
        Task { await directions?.resumeIfPaused() }
    }

    func simulateBlockedRoute() {
        isPaused = false
        isRouteBlocked = true
    }

    /// Asks for a new route from where the user is now. The route service doesn't know about
    /// the obstacle, so the new route is the best one from here, not one that avoids it.
    func reroute() {
        answerBlockedRoute()
        guard let directions, let services else {
            add(TripAnnouncement(text: "New route: turn right in 20 ft, then walk straight", kind: .info))
            return
        }
        Task {
            await say("Finding a new route from here.", category: .system)
            // Ending the trip drops the route; the next location fix plans a new one, and
            // `startWhenRouteIsReady` starts it.
            await services.trip.endTrip()
            directions.retryRoute()
        }
    }

    /// Ends the trip for good (Exit Trip).
    func exit() {
        Task { await directions?.endTrip() }
    }

    private func answerBlockedRoute() {
        if isRouteBlocked { blockDetector.dismiss(at: Date.now.timeIntervalSinceReferenceDate) }
        isRouteBlocked = false
    }
}

private extension TripViewModel {
    func togglePauseIfActive() async {
        if tripState.phase == .active { await togglePause() }
    }

    func resumeIfPaused() async {
        if tripState.phase == .paused { await togglePause() }
    }
}
