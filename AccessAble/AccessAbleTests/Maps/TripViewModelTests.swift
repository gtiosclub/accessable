import Foundation
import Synchronization
import Testing
@testable import AccessAble

/// Reports one fixed authorization and finishes, so `TripViewModel.start()` returns once it is consumed.
private struct FixedAuthorizationProvider: LocationProvider {
    let authorization: LocationAuthorization

    func locationSamples() -> AsyncStream<LocationSample> {
        AsyncStream { continuation in continuation.finish() }
    }

    func headingSamples() -> AsyncStream<HeadingSample> {
        AsyncStream { continuation in continuation.finish() }
    }

    func authorizationStates() -> AsyncStream<LocationAuthorization> {
        AsyncStream { continuation in
            continuation.yield(authorization)
            continuation.finish()
        }
    }

    func requestAuthorization() async {}
}

@MainActor
struct TripViewModelTests {
    @Test(arguments: [
        (LocationAuthorization.notDetermined, false),
        (.restricted, true),
        (.denied, true),
        (.authorized(preciseAccuracy: true), false),
        (.authorized(preciseAccuracy: false), true),
    ])
    func needsLocationAccess(_ authorization: LocationAuthorization, expected: Bool) async {
        var services = AppServices.preview
        services.location = FixedAuthorizationProvider(authorization: authorization)
        // The placeholder's trip stream finishes, so start() returns instead of running for the view's lifetime.
        services.trip = PlaceholderTripProvider()
        let viewModel = TripViewModel(services: services)

        await viewModel.start()

        #expect(viewModel.locationAuthorization == authorization)
        #expect(viewModel.needsLocationAccess == expected)
    }

    @Test(arguments: [
        (LocationAuthorization.notDetermined, false),
        (.restricted, false),
        (.denied, false),
        (.authorized(preciseAccuracy: true), true),
        (.authorized(preciseAccuracy: false), true),
    ])
    func showsUserLocation(_ authorization: LocationAuthorization, expected: Bool) async {
        var services = AppServices.preview
        services.location = FixedAuthorizationProvider(authorization: authorization)
        services.trip = PlaceholderTripProvider()
        let viewModel = TripViewModel(services: services)

        await viewModel.start()

        #expect(viewModel.showsUserLocation == expected)
    }

    @Test(arguments: [LocationAuthorization.denied, .restricted])
    func mapLabelWithoutLocationAccess(_ authorization: LocationAuthorization) async {
        var services = AppServices.preview
        services.location = FixedAuthorizationProvider(authorization: authorization)
        services.trip = PlaceholderTripProvider()
        let viewModel = TripViewModel(services: services)
        await viewModel.start()

        viewModel.setDestination(
            Destination(name: "Library", coordinate: GeoCoordinate(latitude: 33.77434, longitude: -84.39572))
        )

        #expect(viewModel.mapAccessibilityLabel == "Map showing Library. A walking route needs location access.")
    }
}

/// Trip states the test sends, and the routes it was asked to start; never finishes, so run `start()` in a task.
private final class ControlledTripProvider: TripStateProviding, Sendable {
    private let states = Broadcaster<TripState>(replaysLatest: true)
    private let routes = Broadcaster<NavigationRoute?>(replaysLatest: true)
    private let started = Mutex<[NavigationRoute]>([])
    private let preferences = Mutex<[RoutePreferences]>([])

    init(_ state: TripState = .idle) {
        states.send(state)
    }

    func send(_ state: TripState) {
        states.send(state)
    }

    func send(_ route: NavigationRoute?) {
        routes.send(route)
    }

    var startedRoutes: [NavigationRoute] { started.withLock { $0 } }
    var startedPreferences: [RoutePreferences] { preferences.withLock { $0 } }

    func tripStates() -> AsyncStream<TripState> { states.stream() }
    func tripRoutes() -> AsyncStream<NavigationRoute?> { routes.stream() }
    func startTrip(route: NavigationRoute, destination: Destination, preferences: RoutePreferences,
                   resumingAtStep: Int?) async {
        started.withLock { $0.append(route) }
        self.preferences.withLock { $0.append(preferences) }
    }
    func pauseTrip() async {}
    func resumeTrip() async {}
    func endTrip() async {}
    func reroute() async {}
    func reportQuestionEnded(_ reportID: String, outcome: ReportQuestionOutcome) async {}
}

/// Yields fixed fixes with a fixed permission, then finishes.
private struct ScriptedLocationProvider: LocationProvider {
    let samples: [LocationSample]
    var authorization: LocationAuthorization = .authorized(preciseAccuracy: true)

    func locationSamples() -> AsyncStream<LocationSample> {
        AsyncStream { continuation in
            samples.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func headingSamples() -> AsyncStream<HeadingSample> { AsyncStream { $0.finish() } }

    func authorizationStates() -> AsyncStream<LocationAuthorization> {
        AsyncStream { continuation in
            continuation.yield(authorization)
            continuation.finish()
        }
    }

    func requestAuthorization() async {}
}

/// Answers every request with the same route and counts them. While holding, answers wait for `release()`.
private actor CountingRouting: RoutingService {
    private(set) var requestCount = 0
    private(set) var options: [RouteOptions] = []
    let route: NavigationRoute
    private var isHolding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(route: NavigationRoute) {
        self.route = route
    }

    func route(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async throws -> NavigationRoute {
        requestCount += 1
        self.options.append(options)
        if isHolding {
            await withCheckedContinuation { held.append($0) }
        }
        return route
    }

    func hold() {
        isHolding = true
    }

    func release() {
        isHolding = false
        held.forEach { $0.resume() }
        held = []
    }
}

/// Keeps what is submitted.
private actor SubmittedAnnouncements: AnnouncementEngineProtocol {
    private(set) var texts: [String] = []

    func submit(_ event: AnnouncementEvent) async {
        texts.append(event.text)
    }

    nonisolated func deliveredEvents() -> AsyncStream<AnnouncementEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func repeatLast() async {}
    func pause() async {}
    func resume() async {}
    func updateProfile(_ profile: GuidanceProfile) async {}
    func setInCall(_ inCall: Bool) async {}
}

private let origin = GeoCoordinate(latitude: 33.775, longitude: -84.399)
private let library = Destination(name: "Library", coordinate: GeoCoordinate(latitude: 33.776, longitude: -84.399))

private let plannedRoute = try! NavigationRoute(coordinates: [origin, library.coordinate], steps: [
    RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Walk north.", spokenInstruction: "Walk north."),
    RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "You have arrived."),
], estimatedDuration: 90)

/// A different route from the one `CountingRouting` answers with, so a test can tell which was started.
private let pickedRoute = try! NavigationRoute(coordinates: [origin, library.coordinate], steps: [
    RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Head north.", spokenInstruction: "Head north."),
    RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "You have arrived."),
], estimatedDuration: 95)

@MainActor
private final class TripScreen {
    let trip: ControlledTripProvider
    let routing: CountingRouting
    let announcements = SubmittedAnnouncements()
    private let preferencesSuite = "TripScreen-\(UUID())"
    let preferences: RoutePreferencesStore
    let viewModel: TripViewModel
    private let clock = ManualDate()
    private var running: Task<Void, Never>?

    /// - Parameter trip: Pass another screen's to open this one on a trip already running.
    init(fixes: [GeoCoordinate] = [origin], accuracy: Double = 5,
         authorization: LocationAuthorization = .authorized(preciseAccuracy: true),
         trip: ControlledTripProvider = ControlledTripProvider(), route: NavigationRoute = plannedRoute) {
        self.trip = trip
        routing = CountingRouting(route: route)
        var services = AppServices.preview
        services.trip = trip
        services.routing = routing
        services.announcements = announcements
        preferences = RoutePreferencesStore(defaults: UserDefaults(suiteName: preferencesSuite)!)
        services.routePreferences = preferences
        let time = clock.now
        services.location = ScriptedLocationProvider(
            samples: fixes.map { LocationSample(coordinate: $0, horizontalAccuracy: accuracy, timestamp: time) },
            authorization: authorization
        )
        viewModel = TripViewModel(services: services, now: { [clock] in clock.now })
    }

    deinit { UserDefaults.standard.removePersistentDomain(forName: preferencesSuite) }

    func advance(by seconds: TimeInterval) {
        clock.advance(by: seconds)
    }

    var now: Date { clock.now }

    /// Starts the view model on a route an earlier screen found, as the route picker hands on.
    func plan(using planned: PlannedRoute) async {
        viewModel.use(planned)
        running = Task { await viewModel.start() }
        await until { self.viewModel.locationAuthorization != .notDetermined && self.viewModel.lastLocation != nil }
    }

    /// Starts the view model without planning, as when the screen is opened again mid-trip.
    func open() {
        running = Task { await viewModel.start() }
    }

    /// Starts the view model and plans a route to the library.
    func plan() async {
        running = Task { await viewModel.start() }
        viewModel.setDestination(library)
        // routed once both the destination and the first fix are in, whichever comes last
        await until { self.viewModel.route != nil && self.viewModel.locationAuthorization != .notDetermined }
    }

    func show(_ state: TripState) async {
        trip.send(state)
        await until { self.viewModel.tripState == state }
    }

    func stop() {
        running?.cancel()
    }

    func until(_ condition: () -> Bool) async {
        while !condition() { await Task.yield() }
    }
}

private func state(_ phase: TripPhase, maneuver: Maneuver? = nil, distance: Double? = nil) -> TripState {
    TripState(phase: phase, destinationName: "Library", nextManeuver: maneuver, distanceToNextManeuver: distance,
              updatedAt: Date(timeIntervalSince1970: 1))
}

private let turn = Maneuver(kind: .turnRight, instruction: "Turn right onto Ferst Drive.", coordinate: origin)

private let stepFree = RoutePreferences(avoidStairs: true, walkingSpeed: .slow)

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TripStartTests {
    @Test(arguments: [
        (TripPhase.planning, LocationAuthorization.authorized(preciseAccuracy: true), true),
        (.active, .authorized(preciseAccuracy: true), false),
        (.paused, .authorized(preciseAccuracy: true), false),
        (.arrived, .authorized(preciseAccuracy: true), false),
        (.planning, .authorized(preciseAccuracy: false), false),
    ])
    func canStartOnlyWhilePlanningWithPreciseLocation(_ phase: TripPhase, _ authorization: LocationAuthorization,
                                                      expected: Bool) async {
        let screen = TripScreen(authorization: authorization)
        await screen.plan()
        #expect(screen.viewModel.route != nil)
        await screen.show(state(phase))
        #expect(screen.viewModel.canStartTrip == expected)
        screen.stop()
    }

    @Test
    func cannotStartWithoutARoute() async {
        let screen = TripScreen()
        #expect(!screen.viewModel.canStartTrip)
    }

    @Test
    func freshRouteStartsAtOnce() async {
        let screen = TripScreen()
        await screen.plan()
        screen.advance(by: 60)
        await screen.viewModel.startTrip()
        #expect(await screen.routing.requestCount == 1)
        #expect(screen.trip.startedRoutes == [plannedRoute])
        screen.stop()
    }

    @Test
    func handedOnRouteStartsWithoutAskingAgain() async {
        let screen = TripScreen()
        await screen.plan(using: PlannedRoute(destination: library, route: pickedRoute, requestedAt: screen.now))
        #expect(screen.viewModel.plannedRoute?.route == pickedRoute)

        await screen.viewModel.startTrip()
        #expect(await screen.routing.requestCount == 0)
        // the exact route that was picked, not a new one
        #expect(screen.trip.startedRoutes == [pickedRoute])
        screen.stop()
    }

    @Test
    func handedOnRouteOlderThanTwoMinutesIsPlannedAgainFirst() async {
        let screen = TripScreen()
        let planned = PlannedRoute(destination: library, route: pickedRoute, requestedAt: screen.now)
        screen.advance(by: 121)
        await screen.plan(using: planned)

        await screen.viewModel.startTrip()
        #expect(await screen.routing.requestCount == 1)
        #expect(screen.trip.startedRoutes == [plannedRoute])
        screen.stop()
    }

    @Test
    func routeOlderThanTwoMinutesIsPlannedAgainFirst() async {
        let screen = TripScreen()
        await screen.plan()
        screen.advance(by: 121)
        await screen.viewModel.startTrip()
        #expect(await screen.routing.requestCount == 2)
        #expect(screen.trip.startedRoutes.count == 1)
        screen.stop()
    }

    @Test
    func secondTapWhileTheRouteRefreshesStartsNothing() async {
        let screen = TripScreen()
        await screen.plan()
        screen.advance(by: 121)
        await screen.routing.hold()
        let first = Task { await screen.viewModel.startTrip() }
        await screen.until { screen.viewModel.isStartingTrip }
        #expect(!screen.viewModel.canStartTrip)
        #expect(await screen.viewModel.startTrip() == false)

        await screen.routing.release()
        #expect(await first.value)
        #expect(screen.trip.startedRoutes.count == 1)
        #expect(!screen.viewModel.isStartingTrip)
        screen.stop()
    }

    @Test
    func routeThatDoesntStartNearTheUserIsPlannedAgainFirst() async {
        // the route runs north along the meridian; this precise fix is about 30 m east of it
        let screen = TripScreen(fixes: [GeoCoordinate(latitude: 33.775, longitude: -84.39868)])
        await screen.plan()
        await screen.viewModel.startTrip()
        #expect(await screen.routing.requestCount == 2)
        screen.stop()
    }

    @Test
    func endingATripDropsTheRouteAndArrivingThenDoneDropsTheDestination() async {
        let screen = TripScreen()
        await screen.plan()
        await screen.show(state(.active, maneuver: turn, distance: 42))
        await screen.show(state(.planning))
        #expect(screen.viewModel.route == nil)
        #expect(screen.viewModel.destination == library)

        await screen.show(state(.arrived))
        await screen.show(state(.planning))
        #expect(screen.viewModel.destination == nil)
        screen.stop()
    }

    @Test
    func rerouteReplacesTheRouteOnTheMap() async throws {
        let screen = TripScreen()
        await screen.plan()
        await screen.show(state(.active, maneuver: turn, distance: 42))
        let rerouted = try NavigationRoute(coordinates: [turn.coordinate, library.coordinate], steps: [
            RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Walk east.", spokenInstruction: "Walk east."),
            RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "You have arrived."),
        ], estimatedDuration: 60)

        screen.trip.send(rerouted)
        await screen.until { screen.viewModel.route == rerouted }
        screen.stop()
    }

    @Test
    func reopeningTheScreenMidTripShowsTheCurrentRoute() async throws {
        let screen = TripScreen()
        await screen.plan()
        await screen.show(state(.active, maneuver: turn, distance: 42))
        let rerouted = try NavigationRoute(coordinates: [turn.coordinate, library.coordinate], steps: [
            RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Walk east.", spokenInstruction: "Walk east."),
            RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "You have arrived."),
        ], estimatedDuration: 60)
        screen.trip.send(rerouted)
        screen.stop()

        // a new screen on the same trip, with no route handed to it, shows the rerouted line
        let reopened = TripScreen(trip: screen.trip)
        reopened.open()
        await reopened.until { reopened.viewModel.route == rerouted && reopened.viewModel.tripState.phase == .active }
        #expect(await reopened.routing.requestCount == 0)
        reopened.stop()
    }

    @Test(arguments: [
        (state(.active, maneuver: turn, distance: 42), "In about 40 metres, turn right onto Ferst Drive."),
        (state(.paused, maneuver: turn, distance: 3), "In about 10 metres, turn right onto Ferst Drive."),
        (state(.active, maneuver: Maneuver(kind: .turnRight, instruction: "Off route. Finding a new route.",
                                           coordinate: origin)), "Off route. Finding a new route."),
        (state(.active), "Off route."),
        (state(.arrived), "You have arrived at Library."),
        (state(.planning), "No active trip"),
    ])
    func nextInstructionFollowsThePhase(_ tripState: TripState, _ expected: String) async {
        let screen = TripScreen()
        await screen.plan()
        await screen.show(tripState)
        #expect(screen.viewModel.nextInstruction == expected)
        screen.stop()
    }

    @Test(arguments: [
        (TripPhase.active, "Map showing walking directions to Library."),
        (.paused, "Map showing walking directions to Library."),
        (.arrived, "Map showing Library."),
        (.planning, "Map showing a walking route to Library, about 110 metres, about 2 minutes."),
    ])
    func mapLabelFollowsThePhase(_ phase: TripPhase, _ expected: String) async {
        let screen = TripScreen()
        await screen.plan()
        await screen.show(state(phase))
        #expect(screen.viewModel.mapAccessibilityLabel == expected)
        screen.stop()
    }

    @Test
    func aRouteThatPassesAReportWarnsOfIt() async {
        var route = plannedRoute
        route.unavoidedReports = [Report(id: "blocked-1", kind: .blockedPath, coordinate: library.coordinate,
                                         createdAt: .now, expiresAt: .now.addingTimeInterval(3600),
                                         reporterID: "user-1")]
        let screen = TripScreen(route: route)
        await screen.plan()

        // submitted just after the route lands
        while await screen.announcements.texts.isEmpty { await Task.yield() }
        #expect(await screen.announcements.texts == ["A reported obstacle is on this route."])
        screen.stop()
    }

    @Test
    func aRefreshForStartLeavesTheWarningToTheTrip() async {
        var route = plannedRoute
        route.unavoidedReports = [Report(id: "blocked-1", kind: .blockedPath, coordinate: library.coordinate,
                                         createdAt: .now, expiresAt: .now.addingTimeInterval(3600),
                                         reporterID: "user-1")]
        let screen = TripScreen(route: route)
        await screen.plan()
        while await screen.announcements.texts.isEmpty { await Task.yield() }
        screen.advance(by: 121)

        await screen.viewModel.startTrip()

        #expect(await screen.routing.requestCount == 2)
        #expect(await screen.announcements.texts == ["A reported obstacle is on this route."])
        screen.stop()
    }

    @Test
    func aBackupRouteSaysItMayIncludeStairs() async {
        var route = plannedRoute
        route.source = .appleMaps
        let screen = TripScreen(route: route)
        await screen.plan()

        while await screen.announcements.texts.isEmpty { await Task.yield() }
        #expect(await screen.announcements.texts == [RouteSource.backupNotice])
        screen.stop()
    }

    @Test
    func aRefreshForStartLeavesTheBackupNoticeToTheTrip() async {
        var route = plannedRoute
        route.source = .appleMaps
        let screen = TripScreen(route: route)
        await screen.plan()
        while await screen.announcements.texts.isEmpty { await Task.yield() }
        screen.advance(by: 121)

        await screen.viewModel.startTrip()

        #expect(await screen.routing.requestCount == 2)
        #expect(await screen.announcements.texts == [RouteSource.backupNotice])
        screen.stop()
    }

    @Test
    func aBackupRouteWithPreferencesOnSaysTheNotice() async {
        var route = plannedRoute
        route.source = .appleMaps
        let screen = TripScreen(route: route)
        screen.preferences.update(stepFree)
        await screen.plan()

        while await screen.announcements.texts.isEmpty { await Task.yield() }
        #expect(await screen.routing.options == [stepFree.routeOptions])
        #expect(await screen.announcements.texts == [RouteSource.backupNotice])
        screen.stop()
    }

    @Test
    func theRouteIsFoundWithTheUsersPreferences() async {
        let screen = TripScreen()
        screen.preferences.update(stepFree)
        await screen.plan()

        #expect(await screen.routing.options == [stepFree.routeOptions])
        #expect(screen.viewModel.plannedRoute?.preferences == stepFree)
        screen.stop()
    }

    @Test
    func theTripKeepsThePreferencesItsRouteWasFoundWith() async {
        let screen = TripScreen()
        screen.preferences.update(stepFree)
        await screen.plan()
        screen.preferences.update(RoutePreferences())

        await screen.viewModel.startTrip()
        screen.preferences.update(RoutePreferences(avoidSteepHills: true))

        #expect(await screen.routing.requestCount == 1)
        #expect(screen.trip.startedPreferences == [stepFree])
        screen.stop()
    }

    @Test
    func aHandedOnRouteStartsWithItsOwnPreferences() async {
        let screen = TripScreen()
        await screen.plan(using: PlannedRoute(destination: library, route: pickedRoute, requestedAt: screen.now,
                                              preferences: stepFree))

        await screen.viewModel.startTrip()
        #expect(screen.trip.startedPreferences == [stepFree])
        screen.stop()
    }

    @Test
    func aRefreshForStartUsesTheCurrentPreferences() async {
        let screen = TripScreen()
        await screen.plan()
        screen.preferences.update(stepFree)
        screen.advance(by: 121)

        await screen.viewModel.startTrip()
        #expect(await screen.routing.options == [RouteOptions(), stepFree.routeOptions])
        #expect(screen.trip.startedPreferences == [stepFree])
        screen.stop()
    }

    @Test
    func routeReadyAnnouncementRoundsTheDistance() async {
        let screen = TripScreen()
        await screen.plan()
        #expect(screen.viewModel.routeReadyAnnouncement == "Route ready, about 110 metres.")
        screen.stop()
    }
}
