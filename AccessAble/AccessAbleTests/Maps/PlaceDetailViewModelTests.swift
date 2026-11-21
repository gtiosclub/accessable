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

/// A crossing `fraction` of the way along `plannedRoute`.
private func crossing(at fraction: Double) -> CampusCrossing {
    let start = plannedRoute.coordinates[0], end = plannedRoute.coordinates[1]
    return CampusCrossing(coordinate: GeoCoordinate(latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                                                    longitude: start.longitude + (end.longitude - start.longitude) * fraction),
                          control: .marked, audibleSignal: false)
}

private final class ReadCounter: Sendable {
    private let reads = Mutex(0)

    func record() {
        reads.withLock { $0 += 1 }
    }

    var count: Int { reads.withLock { $0 } }
}

/// Two crossings on the route and one a block away, which isn't.
private let campusCrossings = [
    crossing(at: 1.0 / 3), crossing(at: 2.0 / 3),
    CampusCrossing(coordinate: GeoCoordinate(latitude: 33.776, longitude: -84.398), control: .signals, audibleSignal: true),
]

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
        return PlaceDetailViewModel(destination: clough, services: services, campusCrossings: { campusCrossings })
    }

    @Test
    func showsTheRealRoute() async {
        let details = details(routing: FlakyRouting(isOnline: true))
        #expect(details.isLoading)

        await details.start()
        await details.planner.routeTask?.value

        #expect(!details.isLoading)
        #expect(details.route == plannedRoute)
        #expect(details.steps == ["Follow Ferst Drive.", "You have arrived at Clough."])
        #expect(details.summary == "About 4 minutes, 240 metres. No turns, 2 crosswalks.")
        // so the user knows Start is there
        #expect(details.routeReadyAnnouncement == "Route ready. About 4 minutes, 240 metres. No turns, 2 crosswalks.")
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
        // as the route picker makes it from the route place details found
        let details = PlaceDetailViewModel(destination: clough, services: services, planned: planned,
                                           campusCrossings: { campusCrossings })
        #expect(details.summary == "About 4 minutes, 240 metres. No turns, 2 crosswalks.")

        await details.start()
        await details.planner.routeTask?.value

        #expect(details.route == plannedRoute)
        #expect(details.errorMessage == nil)
        #expect(details.plannedRoute == planned)
    }

    @Test
    func switchingUnitsChangesTheSummary() async {
        let distances = DistanceSettings(units: .metres)
        var services = AppServices.preview
        services.location = OneFixLocationProvider()
        services.routing = FlakyRouting(isOnline: true)
        services.trip = PlaceholderTripProvider()
        services.distanceSettings = distances
        let details = PlaceDetailViewModel(destination: clough, services: services, campusCrossings: { [] })
        await details.start()
        await details.planner.routeTask?.value
        #expect(details.summary == "About 4 minutes, 240 metres. No turns.")

        distances.units = .feet
        #expect(details.summary == "About 4 minutes, 0.2 miles. No turns.")
    }

    @Test
    func crossingsAreCountedOncePerRoute() async {
        let reads = ReadCounter()
        var services = AppServices.preview
        services.location = OneFixLocationProvider()
        services.routing = FlakyRouting(isOnline: true)
        services.trip = PlaceholderTripProvider()
        let details = PlaceDetailViewModel(destination: clough, services: services, campusCrossings: {
            reads.record()
            return campusCrossings
        })
        await details.start()
        await details.planner.routeTask?.value
        for _ in 0..<3 {
            #expect(details.summary == "About 4 minutes, 240 metres. No turns, 2 crosswalks.")
        }
        #expect(reads.count == 1)
    }
}
