import CoreLocation
import Foundation
import Observation

/// Owner: Maps + Location (2.x). Active trip: next maneuver, pause/resume, end.
@MainActor
@Observable
final class TripViewModel {
    private(set) var tripState: TripState = .idle
    private(set) var destination: Destination?
    private(set) var route: NavigationRoute?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let locationManager = CLLocationManager()

    /// `destination` and `route` let a caller that already resolved both (e.g. a shared trip) open
    /// straight into a planned trip instead of starting from nothing.
    init(services: AppServices, destination: Destination? = nil, route: NavigationRoute? = nil) {
        self.services = services
        self.destination = destination
        self.route = route
    }

    /// Accepts a destination together with its already-computed route, e.g. handed over from
    /// another screen that resolved both. Replaces whatever destination/route was set before.
    func accept(destination: Destination, route: NavigationRoute) {
        self.destination = destination
        self.route = route
    }

    /// Short, VoiceOver-friendly summary of the planned route, e.g. "about 400 metres, about 6 minutes".
    var routeSummary: String? {
        guard let route else { return nil }
        let minutes = max(1, Int((route.estimatedDuration / 60).rounded()))
        let minuteWord = minutes == 1 ? "minute" : "minutes"
        return "\(SpokenPhrasing.distance(route.totalDistance)), about \(minutes) \(minuteWord)"
    }

    var nextInstruction: String {
        guard let maneuver = tripState.nextManeuver else { return "No active trip" }
        guard let distance = tripState.distanceToNextManeuver else { return maneuver.instruction }
        return "In \(SpokenPhrasing.shortDistance(distance)), \(maneuver.instruction)"
    }

    func start() async {
        // Prompts if undetermined; otherwise a no-op. The map shows the user's location dot once this
        // resolves to an authorized status — no callback needed here.
        locationManager.requestWhenInUseAuthorization()

        for await state in services.trip.tripStates() {
            tripState = state
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
}
