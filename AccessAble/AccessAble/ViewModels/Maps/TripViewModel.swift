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
    private(set) var locationAuthorization: LocationAuthorization = .notDetermined

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var lastLocation: GeoCoordinate?
    // internal so tests can await the request
    @ObservationIgnored private(set) var routeTask: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
    }

    func setDestination(_ destination: Destination) {
        self.destination = destination
        route = nil
        requestRoute()
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
        lastLocation = sample.coordinate
        // a destination picked before the first fix is still waiting for its route
        if destination != nil, route == nil, routeTask == nil {
            requestRoute()
        }
    }

    // cancels any in-flight request so a route to an old destination can't replace the new one
    private func requestRoute() {
        routeTask?.cancel()
        routeTask = nil
        guard let destination, let origin = lastLocation else { return }
        routeTask = Task {
            do {
                let route = try await services.routing.route(
                    from: origin, to: destination.coordinate, options: RouteOptions()
                )
                guard !Task.isCancelled else { return }
                self.route = route
            } catch {
                guard !Task.isCancelled else { return }
                log.error("Routing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
