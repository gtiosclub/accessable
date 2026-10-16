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

    @ObservationIgnored private let services: AppServices
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

    init(services: AppServices) {
        self.services = services
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
        guard let maneuver = tripState.nextManeuver else { return "No active trip" }
        guard let distance = tripState.distanceToNextManeuver else { return maneuver.instruction }
        return "In \(SpokenPhrasing.shortDistance(distance)), \(maneuver.instruction)"
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
        guard let route else {
            // the error message element says why; repeating it here would read it twice
            if routeError != nil { return "Map showing \(name). No walking route." }
            switch locationAuthorization {
            case .denied, .restricted: return "Map showing \(name). A walking route needs location access."
            case .notDetermined, .authorized: return "Map showing \(name). Finding a walking route."
            }
        }
        // SpokenPhrasing's half-metre precision is noise over a whole route
        let metres = max(10, Int((route.totalDistance / 10).rounded()) * 10)
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

    private func receive(_ state: TripState) { tripState = state }
    private func receive(_ authorization: LocationAuthorization) { locationAuthorization = authorization }

    private func receive(_ sample: LocationSample) {
        let firstSampleTime = firstSampleTime ?? sample.timestamp
        self.firstSampleTime = firstSampleTime
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
        routeTask = Task {
            // a finished request no longer blocks new ones; a cancelled one has already been replaced
            defer { if !Task.isCancelled { routeTask = nil } }
            do {
                let route = try await services.routing.route(
                    from: origin, to: destination.coordinate, options: RouteOptions()
                )
                guard !Task.isCancelled else { return }
                self.route = route
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
