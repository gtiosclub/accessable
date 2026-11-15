import Foundation
import Synchronization
import Testing
@testable import AccessAble

/// One good fix with full permission, then finishes.
private struct OneFixLocationProvider: LocationProvider {
    var authorization: LocationAuthorization = .authorized(preciseAccuracy: true)

    func locationSamples() -> AsyncStream<LocationSample> {
        AsyncStream { continuation in
            continuation.yield(LocationSample(coordinate: origin, horizontalAccuracy: 5, timestamp: .now))
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

/// Fails like Valhalla does offline until `goOnline()`, then answers with `plannedRoute`.
private final class FlakyRouting: RoutingService {
    private let isOnline: Mutex<Bool>

    init(isOnline: Bool) {
        self.isOnline = Mutex(isOnline)
    }

    func goOnline() { isOnline.withLock { $0 = true } }

    func route(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async throws -> NavigationRoute {
        guard isOnline.withLock({ $0 }) else { throw RoutingError.serverUnavailable }
        return plannedRoute
    }
}

private let origin = GeoCoordinate(latitude: 33.775, longitude: -84.399)
private let clough = Destination(
    name: "Clough Undergraduate Learning Commons",
    coordinate: GeoCoordinate(latitude: 33.7746, longitude: -84.3964),
    address: "266 4th St NW, Atlanta, GA"
)

private let plannedRoute = try! NavigationRoute(coordinates: [origin, clough.coordinate], steps: [
    RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Walk east.", spokenInstruction: "Walk east on Ferst Drive."),
    RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive", spokenInstruction: "You have arrived at Clough."),
], estimatedDuration: 260)

@MainActor
struct PlaceDetailViewModelTests {
    private func details(
        routing: FlakyRouting,
        location: some LocationProvider = OneFixLocationProvider()
    ) -> PlaceDetailViewModel {
        var services = AppServices.preview
        services.location = location
        services.routing = routing
        // The placeholder's streams finish, so start() returns once the fix is used.
        services.trip = PlaceholderTripProvider()
        return PlaceDetailViewModel(destination: clough, services: services)
    }

    @Test
    func showsTheRealRoute() async {
        let details = details(routing: FlakyRouting(isOnline: true))
        #expect(details.isLoading)

        await details.start()
        await details.planner.routeTask?.value

        #expect(!details.isLoading)
        #expect(details.route == plannedRoute)
        #expect(details.steps == ["Walk east on Ferst Drive.", "You have arrived at Clough."])
        #expect(details.summary == PlaceDetailViewModel.summary(
            metres: plannedRoute.totalDistance, seconds: plannedRoute.estimatedDuration
        ))
    }

    @Test
    func offlineSaysSoAndTryAgainWorks() async {
        let routing = FlakyRouting(isOnline: false)
        let details = details(routing: routing)

        await details.start()
        await details.planner.routeTask?.value

        #expect(details.route == nil)
        #expect(!details.isLoading)
        #expect(details.errorMessage == "Couldn't reach the routing service. Check your connection and try again.")

        routing.goOnline()
        details.retry()
        await details.planner.routeTask?.value

        #expect(details.errorMessage == nil)
        #expect(details.route == plannedRoute)
    }

    @Test
    func withoutLocationItSaysWhy() async {
        let details = details(
            routing: FlakyRouting(isOnline: true),
            location: OneFixLocationProvider(authorization: .denied)
        )
        await details.start()

        #expect(details.needsLocationAccess)
        #expect(!details.isLoading)
    }

    @Test
    func aHandedOnRouteIsShownWithoutAskingAgain() async {
        // Offline, so asking again would show an error instead of the route.
        let services = {
            var services = AppServices.preview
            services.location = OneFixLocationProvider()
            services.routing = FlakyRouting(isOnline: false)
            services.trip = PlaceholderTripProvider()
            return services
        }()
        let planned = PlannedRoute(destination: clough, route: plannedRoute, requestedAt: .now)
        let details = PlaceDetailViewModel(destination: clough, services: services, planned: planned)

        await details.start()
        await details.planner.routeTask?.value

        #expect(details.route == plannedRoute)
        #expect(details.errorMessage == nil)
        #expect(details.plannedRoute == planned)
    }

    @Test
    func summaryReadsAsAWalk() {
        #expect(PlaceDetailViewModel.summary(metres: 352, seconds: 290) == "350 m · about 5 min walk")
        #expect(PlaceDetailViewModel.summary(metres: 1840, seconds: 1500) == "1.8 km · about 25 min walk")
        #expect(PlaceDetailViewModel.summary(metres: 3, seconds: 4) == "10 m · about 1 min walk")
    }
}
