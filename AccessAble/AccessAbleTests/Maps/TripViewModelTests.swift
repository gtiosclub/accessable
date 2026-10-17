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

    func tripStates() -> AsyncStream<TripState> { states.stream() }
    func tripRoutes() -> AsyncStream<NavigationRoute?> { routes.stream() }
    func startTrip(route: NavigationRoute, destination: Destination) async { started.withLock { $0.append(route) } }
    func pauseTrip() async {}
    func resumeTrip() async {}
    func endTrip() async {}
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

private let origin = GeoCoordinate(latitude: 33.775, longitude: -84.399)
private let library = Destination(name: "Library", coordinate: GeoCoordinate(latitude: 33.776, longitude: -84.399))

private let plannedRoute = try! NavigationRoute(coordinates: [origin, library.coordinate], steps: [
    RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Walk north.", spokenInstruction: "Walk north."),
    RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "You have arrived."),
], estimatedDuration: 90)

private final class ManualDate: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_700_000_000))

    var now: Date { date.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        date.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

@MainActor
private final class TripScreen {
    let trip: ControlledTripProvider
    let routing: CountingRouting
    let viewModel: TripViewModel
    private let clock = ManualDate()
    private var running: Task<Void, Never>?

    init(fixes: [GeoCoordinate] = [origin], accuracy: Double = 5,
         authorization: LocationAuthorization = .authorized(preciseAccuracy: true)) {
        trip = ControlledTripProvider()
        routing = CountingRouting(route: plannedRoute)
        var services = AppServices.preview
        services.trip = trip
        services.routing = routing
        let time = clock.now
        services.location = ScriptedLocationProvider(
            samples: fixes.map { LocationSample(coordinate: $0, horizontalAccuracy: accuracy, timestamp: time) },
            authorization: authorization
        )
        viewModel = TripViewModel(services: services, now: { [clock] in clock.now })
    }

    func advance(by seconds: TimeInterval) {
        clock.advance(by: seconds)
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
    func routeReadyAnnouncementRoundsTheDistance() async {
        let screen = TripScreen()
        await screen.plan()
        #expect(screen.viewModel.routeReadyAnnouncement == "Route ready, about 110 metres.")
        screen.stop()
    }
}
