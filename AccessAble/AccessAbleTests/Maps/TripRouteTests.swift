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
    let samples: [LocationSample]

    func locationSamples() -> AsyncStream<LocationSample> {
        AsyncStream { continuation in
            for sample in samples {
                continuation.yield(sample)
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

/// Records each request and answers with a straight route, or with `failure` for the first `failureCount` requests.
/// Requests to `heldDestination` wait for `release()`.
private actor FakeRouting: RoutingService {
    private(set) var requests: [RouteRequest] = []
    private let failure: RoutingError?
    private let failureCount: Int
    private let duration: Double
    private let heldDestination: GeoCoordinate?
    private var released = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(
        failure: RoutingError? = nil,
        failingFirst failureCount: Int = .max,
        duration: Double = 60,
        holding heldDestination: GeoCoordinate? = nil
    ) {
        self.failure = failure
        self.failureCount = failureCount
        self.duration = duration
        self.heldDestination = heldDestination
    }

    func route(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async throws -> NavigationRoute {
        let index = requests.count
        requests.append(RouteRequest(origin: origin, destination: destination))
        if destination == heldDestination, !released {
            await withCheckedContinuation { held.append($0) }
        }
        if let failure, index < failureCount { throw failure }
        return try NavigationRoute(
            coordinates: [origin, destination],
            steps: [
                RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Depart", spokenInstruction: "Depart"),
                RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "Arrive"),
            ],
            estimatedDuration: duration
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
    makeViewModel(samples: locations.map { fix($0) }, routing: routing)
}

@MainActor
private func makeViewModel(samples: [LocationSample], routing: FakeRouting) -> TripViewModel {
    var services = AppServices.preview
    services.location = FixedLocationProvider(samples: samples)
    // The placeholder's trip stream finishes, so start() returns instead of running for the view's lifetime.
    services.trip = PlaceholderTripProvider()
    services.routing = routing
    return TripViewModel(services: services)
}

private func fix(_ coordinate: GeoCoordinate, accuracy: Double = 5, at timestamp: Date = .now) -> LocationSample {
    LocationSample(coordinate: coordinate, horizontalAccuracy: accuracy, timestamp: timestamp)
}

private let firstFixTime = Date(timeIntervalSinceReferenceDate: 0)

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
        #expect(viewModel.routeError == .noRouteFound)
    }

    @Test
    func retryAfterFailureRoutes() async {
        let routing = FakeRouting(failure: .serverUnavailable, failingFirst: 1)
        let viewModel = makeViewModel(locations: [start], routing: routing)
        await viewModel.start()
        viewModel.setDestination(library)
        await viewModel.routeTask?.value

        viewModel.retryRoute()
        #expect(viewModel.routeError == nil)
        await viewModel.routeTask?.value

        #expect(await routing.requests.count == 2)
        #expect(viewModel.route?.coordinates == [start, library.coordinate])
        #expect(viewModel.routeError == nil)
    }

    @Test
    func newDestinationClearsFailure() async {
        let viewModel = makeViewModel(locations: [start], routing: FakeRouting(failure: .noRouteFound))
        await viewModel.start()
        viewModel.setDestination(library)
        await viewModel.routeTask?.value

        viewModel.setDestination(studentCenter)

        #expect(viewModel.routeError == nil)
    }

    @Test
    func fixesAfterFailureDoNotRequestAgain() async {
        let routing = FakeRouting(failure: .serverUnavailable)
        let viewModel = makeViewModel(locations: [start], routing: routing)
        await viewModel.start()
        viewModel.setDestination(library)
        await viewModel.routeTask?.value

        // the provider's streams start over, delivering more fixes
        await viewModel.start()

        #expect(await routing.requests.count == 1)
        #expect(viewModel.routeError == .serverUnavailable)
    }

    @Test
    func eachFailureIsCounted() async {
        let viewModel = makeViewModel(locations: [start], routing: FakeRouting(failure: .serverUnavailable))
        await viewModel.start()
        viewModel.setDestination(library)
        await viewModel.routeTask?.value

        viewModel.retryRoute()
        await viewModel.routeTask?.value

        #expect(viewModel.routeFailureCount == 2)
        #expect(viewModel.routeError == .serverUnavailable)
    }

    @Test
    func inaccurateFixIsNotUsedAsOrigin() async {
        let routing = FakeRouting()
        let viewModel = makeViewModel(samples: [fix(start, accuracy: 250), fix(later, accuracy: 100)], routing: routing)

        viewModel.setDestination(library)
        await viewModel.start()
        await viewModel.routeTask?.value

        #expect(await routing.requests == [RouteRequest(origin: later, destination: library.coordinate)])
    }

    @Test
    func poorFixesWaitBeforeRouting() async {
        let routing = FakeRouting()
        let viewModel = makeViewModel(
            samples: [
                fix(start, accuracy: 250, at: firstFixTime),
                fix(later, accuracy: 250, at: firstFixTime.addingTimeInterval(9)),
            ],
            routing: routing
        )

        viewModel.setDestination(library)
        await viewModel.start()

        #expect(await routing.requests.isEmpty)
        #expect(viewModel.mapAccessibilityLabel == "Map showing Library. Finding a walking route.")
    }

    @Test
    func poorFixesFallBackToBestAfterWait() async {
        let routing = FakeRouting()
        let viewModel = makeViewModel(
            samples: [
                fix(start, accuracy: 300, at: firstFixTime),
                fix(later, accuracy: 250, at: firstFixTime.addingTimeInterval(5)),
                fix(start, accuracy: 400, at: firstFixTime.addingTimeInterval(10)),
            ],
            routing: routing
        )

        viewModel.setDestination(library)
        await viewModel.start()
        await viewModel.routeTask?.value

        #expect(await routing.requests == [RouteRequest(origin: later, destination: library.coordinate)])
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

    @Test
    func mapLabelWithoutDestination() async {
        let viewModel = makeViewModel(locations: [start], routing: FakeRouting())
        await viewModel.start()

        #expect(viewModel.mapAccessibilityLabel == "Map. No destination chosen.")
    }

    @Test
    func mapLabelBeforeRoute() async {
        let viewModel = makeViewModel(locations: [], routing: FakeRouting())
        await viewModel.start()
        viewModel.setDestination(library)

        #expect(viewModel.mapAccessibilityLabel == "Map showing Library. Finding a walking route.")
    }

    @Test
    func mapLabelAfterFailure() async {
        let viewModel = makeViewModel(locations: [start], routing: FakeRouting(failure: .noRouteFound))
        await viewModel.start()
        viewModel.setDestination(library)
        await viewModel.routeTask?.value

        #expect(viewModel.mapAccessibilityLabel == "Map showing Library. No walking route.")
    }

    @Test(arguments: [
        (RoutingError.noRouteFound, "No walking route to Library was found."),
        (.serverUnavailable, "Couldn't reach the routing service. Check your connection and try again."),
        (.invalidResponse, "The routing service sent a route AccessAble couldn't read. Try again."),
    ])
    func routeErrorMessage(_ error: RoutingError, expected: String) async {
        let viewModel = makeViewModel(locations: [start], routing: FakeRouting(failure: error))
        await viewModel.start()
        viewModel.setDestination(library)
        await viewModel.routeTask?.value

        #expect(viewModel.routeErrorMessage == expected)
    }

    // start to the library is 311.9 m, which rounds to 310
    @Test(arguments: [
        (60.0, "about 1 minute"),
        (29.0, "about 1 minute"),
        (89.0, "about 1 minute"),
        (91.0, "about 2 minutes"),
        (260.0, "about 4 minutes"),
    ])
    func mapLabelWithRoute(duration: Double, spokenDuration: String) async {
        let viewModel = makeViewModel(locations: [start], routing: FakeRouting(duration: duration))
        await viewModel.start()
        viewModel.setDestination(library)
        await viewModel.routeTask?.value

        #expect(viewModel.mapAccessibilityLabel
            == "Map showing a walking route to Library, about 310 metres, \(spokenDuration).")
    }

    @Test
    func mapLabelForVeryShortRouteSaysTenMetres() async {
        let nextDoor = Destination(
            name: "Next door", coordinate: GeoCoordinate(latitude: 33.77502, longitude: -84.3990)
        )
        let viewModel = makeViewModel(locations: [start], routing: FakeRouting())
        await viewModel.start()
        viewModel.setDestination(nextDoor)
        await viewModel.routeTask?.value

        #expect(viewModel.mapAccessibilityLabel
            == "Map showing a walking route to Next door, about 10 metres, about 1 minute.")
    }
}
