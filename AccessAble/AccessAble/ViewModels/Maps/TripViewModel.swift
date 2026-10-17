import Foundation
import Observation
import os

private let log = Logger(subsystem: "AccessAble", category: "Trip")

/// Owner: Maps + Location (2.x). Active trip: next maneuver, pause/resume, end.
@MainActor
@Observable
final class TripViewModel {
    private(set) var tripState: TripState = .idle
    private(set) var destination: Destination?
    private(set) var route: NavigationRoute?
    private(set) var routeError: RoutingError?
    /// Counts stored failures, so a repeat of the same error is still announced.
    private(set) var routeFailureCount = 0
    private(set) var locationAuthorization: LocationAuthorization = .notDetermined
    /// True while Start refreshes a stale route, so a second tap can't start the trip twice.
    private(set) var isStartingTrip = false

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var routeRequestedAt: Date?
    @ObservationIgnored private var latestPreciseFix: LocationSample?
    @ObservationIgnored private var lastLocation: GeoCoordinate?
    @ObservationIgnored private var firstSampleTime: Date?
    @ObservationIgnored private var bestSample: LocationSample?
    // internal so tests can await the request
    @ObservationIgnored private(set) var routeTask: Task<Void, Never>?

    // a first fix can be hundreds of metres off; 100 m is tight enough to start on the right side of a building
    // and loose enough that most phones indoors still qualify. Rougher fixes are a fallback after `poorFixWait`.
    private static let maximumOriginAccuracy: Double = 100
    // long enough for GPS to settle outdoors, short enough that someone stuck indoors isn't left waiting
    private static let poorFixWait: TimeInterval = 10
    // a route this old was likely planned indoors or before the user moved, so starting on it would put them off route
    private static let maximumRouteAge: TimeInterval = 120
    private static let maximumStartFixAccuracy: Double = 20
    private static let maximumStartOffset: Double = 20

    init(services: AppServices, now: @escaping () -> Date = { .now }) {
        self.services = services
        self.now = now
    }

    func setDestination(_ destination: Destination) {
        self.destination = destination
        route = nil
        routeError = nil
        requestRoute()
    }

    func retryRoute() {
        routeError = nil
        requestRoute()
    }

    /// Spoken as well as shown, so it reads as a sentence.
    var routeErrorMessage: String? {
        guard let routeError, let destination else { return nil }
        switch routeError {
        case .noRouteFound: return "No walking route to \(destination.name) was found."
        case .serverUnavailable: return "Couldn't reach the routing service. Check your connection and try again."
        case .invalidResponse: return "The routing service sent a route AccessAble couldn't read. Try again."
        }
    }

    var nextInstruction: String {
        if tripState.phase == .arrived {
            return "You have arrived at \(tripState.destinationName ?? destination?.name ?? "your destination")."
        }
        guard let maneuver = tripState.nextManeuver else {
            return tripState.phase == .active ? "Off route." : "No active trip"
        }
        // no distance while off route: the instruction says what is happening instead
        guard let distance = tripState.distanceToNextManeuver else { return maneuver.instruction }
        let instruction = maneuver.instruction.prefix(1).lowercased() + maneuver.instruction.dropFirst()
        return "In about \(Self.roundedMetres(distance)) metres, \(instruction)"
    }

    var canStartTrip: Bool {
        route != nil && !isStartingTrip && tripState.phase == .planning
            && locationAuthorization == .authorized(preciseAccuracy: true)
    }

    /// Posted once when a route arrives, since VoiceOver doesn't read the map changing.
    var routeReadyAnnouncement: String? {
        route.map { "Route ready, about \(Self.roundedMetres($0.totalDistance)) metres." }
    }

    /// Turn-by-turn guidance can't place the user at each turn without Precise Location, so reduced accuracy
    /// counts as missing access.
    var needsLocationAccess: Bool {
        switch locationAuthorization {
        case .restricted, .denied, .authorized(preciseAccuracy: false): true
        case .notDetermined, .authorized(preciseAccuracy: true): false
        }
    }

    /// VoiceOver reads the map as this one element.
    var mapAccessibilityLabel: String {
        guard let name = destination?.name ?? tripState.destinationName else { return "Map. No destination chosen." }
        switch tripState.phase {
        // re-entering the screen mid-trip has no route, so this mustn't depend on one
        case .active, .paused: return "Map showing walking directions to \(name)."
        case .arrived: return "Map showing \(name)."
        case .planning: break
        }
        guard let route else {
            // the error message element says why; repeating it here would read it twice
            if routeError != nil { return "Map showing \(name). No walking route." }
            switch locationAuthorization {
            case .denied, .restricted: return "Map showing \(name). A walking route needs location access."
            case .notDetermined, .authorized: return "Map showing \(name). Finding a walking route."
            }
        }
        let metres = Self.roundedMetres(route.totalDistance)
        let minutes = max(1, Int((route.estimatedDuration / 60).rounded()))
        let duration = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        return "Map showing a walking route to \(name), about \(metres) metres, about \(duration)."
    }

    /// Reduced accuracy still shows, as an approximate area instead of a dot.
    var showsUserLocation: Bool {
        if case .authorized = locationAuthorization { true } else { false }
    }

    func start() async {
        await services.location.requestAuthorization()

        await withDiscardingTaskGroup { group in
            group.addTask { [services] in
                for await state in services.trip.tripStates() {
                    await self.receive(state)
                }
            }
            group.addTask { [services] in
                for await authorization in services.location.authorizationStates() {
                    await self.receive(authorization)
                }
            }
            group.addTask { [services] in
                for await sample in services.location.locationSamples() {
                    await self.receive(sample)
                }
            }
        }
    }

    func togglePause() async {
        switch tripState.phase {
        case .active: await services.trip.pauseTrip()
        case .paused: await services.trip.resumeTrip()
        case .planning, .arrived: break
        }
    }

    func endTrip() async {
        await services.trip.endTrip()
    }

    /// Asks for a fresh route first when this one is old or doesn't start where the user now is. Returns whether the
    /// trip started.
    @discardableResult
    func startTrip() async -> Bool {
        guard canStartTrip, let route else { return false }
        isStartingTrip = true
        defer { isStartingTrip = false }
        if isStale(route) {
            requestRoute()
            await routeTask?.value
            guard routeError == nil else { return false }
        }
        // the destination or route may have changed during the refresh
        guard let route = self.route, let destination, tripState.phase == .planning else { return false }
        await services.trip.startTrip(route: route, destination: destination)
        return true
    }

    private func isStale(_ route: NavigationRoute) -> Bool {
        if let routeRequestedAt, now().timeIntervalSince(routeRequestedAt) > Self.maximumRouteAge { return true }
        guard let latestPreciseFix else { return false }
        return abs(route.projection(of: latestPreciseFix.coordinate).sideOffset) > Self.maximumStartOffset
    }

    // SpokenPhrasing's half-metre precision is noise at these distances
    private static func roundedMetres(_ distance: Double) -> Int {
        max(10, Int((distance / 10).rounded()) * 10)
    }

    private func receive(_ state: TripState) {
        let previous = tripState.phase
        tripState = state
        switch (previous, state.phase) {
        // a finished trip's route starts where the user no longer is; the next fix plans a new one
        case (.active, .planning), (.paused, .planning), (_, .arrived):
            route = nil
            routeRequestedAt = nil
        // "Done" after arriving: there is nowhere left to walk to
        case (.arrived, .planning):
            destination = nil
        default:
            break
        }
    }
    private func receive(_ authorization: LocationAuthorization) { locationAuthorization = authorization }

    private func receive(_ sample: LocationSample) {
        let firstSampleTime = firstSampleTime ?? sample.timestamp
        self.firstSampleTime = firstSampleTime
        if sample.horizontalAccuracy <= Self.maximumStartFixAccuracy {
            latestPreciseFix = sample
        }
        if sample.horizontalAccuracy < bestSample?.horizontalAccuracy ?? .infinity {
            bestSample = sample
        }
        if sample.horizontalAccuracy <= Self.maximumOriginAccuracy {
            lastLocation = sample.coordinate
        } else if sample.timestamp.timeIntervalSince(firstSampleTime) >= Self.poorFixWait, let bestSample,
                  bestSample.horizontalAccuracy > Self.maximumOriginAccuracy {
            // no accurate fix has come, so a rough origin beats no route at all
            lastLocation = bestSample.coordinate
        } else {
            return
        }
        // a destination picked before the first fix is still waiting for its route. After a failure only "Try again"
        // asks again: fixes arrive about once a second and the server's fair-use limit is about one request a second
        if destination != nil, route == nil, routeTask == nil, routeError == nil {
            requestRoute()
        }
    }

    // cancels any in-flight request so a route to an old destination can't replace the new one
    private func requestRoute() {
        routeTask?.cancel()
        routeTask = nil
        guard let destination, let origin = lastLocation else { return }
        let requestedAt = now()
        routeTask = Task {
            // a finished request no longer blocks new ones; a cancelled one has already been replaced
            defer { if !Task.isCancelled { routeTask = nil } }
            do {
                let route = try await services.routing.route(
                    from: origin, to: destination.coordinate, options: RouteOptions()
                )
                guard !Task.isCancelled else { return }
                self.route = route
                routeRequestedAt = requestedAt
            } catch {
                guard !Task.isCancelled else { return }
                log.error("Routing failed: \(error.localizedDescription, privacy: .public)")
                // the service only throws RoutingError, but anything else still has to reach the user
                routeError = error as? RoutingError ?? .invalidResponse
                routeFailureCount += 1
            }
        }
    }
}
