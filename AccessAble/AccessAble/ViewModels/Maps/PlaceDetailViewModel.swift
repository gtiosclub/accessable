import Foundation
import Observation

/// Owner: Maps (2.x). State for a place's details: its name and address, and the real
/// walking route to it from where the user is: distance, time and steps.
///
/// The route comes from `TripViewModel`, which already picks a good enough GPS fix to start
/// from, asks the routing service, and reports failures. This only formats what it found.
@MainActor
@Observable
final class PlaceDetailViewModel {
    let destination: Destination
    /// Finds the route. Kept so its retry and error rules aren't copied here.
    let planner: TripViewModel

    init(destination: Destination, services: AppServices) {
        self.destination = destination
        planner = TripViewModel(services: services)
    }

    var route: NavigationRoute? { planner.route }
    var errorMessage: String? { planner.routeErrorMessage }
    var needsLocationAccess: Bool {
        switch planner.locationAuthorization {
        case .denied, .restricted: true
        case .notDetermined, .authorized: false
        }
    }

    /// Waiting for a location fix or for the routing service.
    var isLoading: Bool { route == nil && errorMessage == nil && !needsLocationAccess }

    /// "650 m · about 9 min walk".
    var summary: String? {
        route.map { Self.summary(metres: $0.totalDistance, seconds: $0.estimatedDuration) }
    }

    /// What each step says, in order, as spoken during the trip.
    var steps: [String] { route?.steps.map(\.spokenInstruction) ?? [] }

    /// Asks for the route, then follows location until cancelled. A route found earlier is
    /// kept when the screen comes back.
    func start() async {
        if planner.destination == nil { planner.setDestination(destination) }
        await planner.start()
    }

    func retry() {
        planner.retryRoute()
    }

    static func summary(metres: Double, seconds: Double) -> String {
        let distance = metres < 1000
            ? "\(max(10, Int((metres / 10).rounded()) * 10)) m"
            : (metres / 1000).formatted(.number.precision(.fractionLength(1))) + " km"
        let minutes = max(1, Int((seconds / 60).rounded()))
        return "\(distance) · about \(minutes) min walk"
    }
}
