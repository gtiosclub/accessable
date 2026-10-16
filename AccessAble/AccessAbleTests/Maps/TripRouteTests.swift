import Foundation
import Testing
@testable import AccessAble

private let start = GeoCoordinate(latitude: 33.7750, longitude: -84.3990)
private let later = GeoCoordinate(latitude: 33.7752, longitude: -84.3988)
private let library = Destination(name: "Library", coordinate: GeoCoordinate(latitude: 33.77434, longitude: -84.39572))
private let studentCenter = Destination(
    name: "Student Center", coordinate: GeoCoordinate(latitude: 33.7738, longitude: -84.3988)
)

/// Delivers fixed samples with full access, then finishes so `TripViewModel.start()` returns.
private struct FixedLocationProvider: LocationProvider {
    let coordinates: [GeoCoordinate]

    func locationSamples() -> AsyncStream<LocationSample> {
        AsyncStream { continuation in
            for coordinate in coordinates {
                continuation.yield(LocationSample(coordinate: coordinate, horizontalAccuracy: 5, timestamp: .now))
            }
            continuation.finish()
        }
    }

    func headingSamples() -> AsyncStream<HeadingSample> {
        AsyncStream { continuation in continuation.finish() }
    }

    func authorizationStates() -> AsyncStream<LocationAuthorization> {
        AsyncStream { continuation in
            continuation.yield(.authorized(preciseAccuracy: true))
            continuation.finish()
        }
    }

    func requestAuthorization() async {}
}

private struct RouteRequest: Equatable {
    let origin: GeoCoordinate
    let destination: GeoCoordinate
}

/// Records each request and answers with a straight route. Requests to `heldDestination` wait for `release()`.
private actor FakeRouting: RoutingService {
    private(set) var requests: [RouteRequest] = []
    private let failure: RoutingError?
    private let heldDestination: GeoCoordinate?
    private var released = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(failure: RoutingError? = nil, holding heldDestination: GeoCoordinate? = nil) {
        self.failure = failure
        self.heldDestination = heldDestination
    }

    func route(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async throws -> NavigationRoute {
        requests.append(RouteRequest(origin: origin, destination: destination))
        if destination == heldDestination, !released {
            await withCheckedContinuation { held.append($0) }
        }
        if let failure { throw failure }
        return try NavigationRoute(
            coordinates: [origin, destination],
            steps: [
                RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Depart", spokenInstruction: "Depart"),
                RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "Arrive"),
            ],
            estimatedDuration: 60
        )
    }

    func release() {
        released = true
        held.forEach { $0.resume() }
        held.removeAll()
    }
}

@MainActor
private func makeViewModel(locations: [GeoCoordinate], routing: FakeRouting) -> TripViewModel {
    var services = AppServices.preview
    services.location = FixedLocationProvider(coordinates: locations)
    // The placeholder's trip stream finishes, so start() returns instead of running for the view's lifetime.
    services.trip = PlaceholderTripProvider()
    services.routing = routing
    return TripViewModel(services: services)
}

@MainActor
struct TripRouteTests {
    @Test
    func routesFromLatestLocationToDestination() async {
        let routing = FakeRouting()
        let viewModel = makeViewModel(locations: [start, later], routing: routing)
        await viewModel.start()

        viewModel.setDestination(library)
        await viewModel.routeTask?.value

        #expect(await routing.requests == [RouteRequest(origin: later, destination: library.coordinate)])
        #expect(viewModel.route?.coordinates == [later, library.coordinate])
    }

    @Test
    func destinationBeforeFirstFixRoutesOnceLocationArrives() async {
        let routing = FakeRouting()
        let viewModel = makeViewModel(locations: [start, later], routing: routing)

        viewModel.setDestination(library)
        #expect(viewModel.routeTask == nil)

        await viewModel.start()
        await viewModel.routeTask?.value

        // later fixes don't re-request while a route exists or is on its way
        #expect(await routing.requests == [RouteRequest(origin: start, destination: library.coordinate)])
        #expect(viewModel.route?.coordinates == [start, library.coordinate])
    }

    @Test
    func newDestinationReplacesRoute() async {
        let routing = FakeRouting()
        let viewModel = makeViewModel(locations: [start], routing: routing)
        await viewModel.start()
        viewModel.setDestination(library)
        await viewModel.routeTask?.value

        viewModel.setDestination(studentCenter)
        #expect(viewModel.route == nil)
        await viewModel.routeTask?.value

        #expect(viewModel.destination == studentCenter)
        #expect(viewModel.route?.coordinates == [start, studentCenter.coordinate])
    }

    @Test
    func staleRouteDoesNotReplaceNewerOne() async {
        let routing = FakeRouting(holding: library.coordinate)
        let viewModel = makeViewModel(locations: [start], routing: routing)
        await viewModel.start()

        viewModel.setDestination(library)
        let firstRequest = viewModel.routeTask
        viewModel.setDestination(studentCenter)
        await viewModel.routeTask?.value
        await routing.release()
        await firstRequest?.value

        #expect(viewModel.route?.coordinates == [start, studentCenter.coordinate])
    }

    @Test
    func failedRequestLeavesNoRoute() async {
        let routing = FakeRouting(failure: .noRouteFound)
        let viewModel = makeViewModel(locations: [start], routing: routing)
        await viewModel.start()

        viewModel.setDestination(library)
        await viewModel.routeTask?.value

        #expect(viewModel.destination == library)
        #expect(viewModel.route == nil)
    }

    @Test
    func noLocationMeansNoRequest() async {
        let routing = FakeRouting()
        let viewModel = makeViewModel(locations: [], routing: routing)
        await viewModel.start()

        viewModel.setDestination(library)

        #expect(viewModel.routeTask == nil)
        #expect(await routing.requests.isEmpty)
        #expect(viewModel.route == nil)
    }
}
