import Foundation
import Observation

/// Owner: Maps (2.x). State for a place's details and the route picker: the place's name and
/// address, and the real walking route to it from where the user is: its summary and steps.
///
/// The route comes from `TripViewModel`, which already picks a good enough GPS fix to start
/// from, asks the routing service, and reports failures. This only formats what it found.
@MainActor
@Observable
final class PlaceDetailViewModel {
    let destination: Destination
    /// Finds the route. Kept so its retry and error rules aren't copied here.
    let planner: TripViewModel
    @ObservationIgnored private let distanceSettings: DistanceSettings
    /// Read when a route first arrives, so tests can avoid parsing the bundled file.
    @ObservationIgnored private let campusCrossings: @Sendable () -> [CampusCrossing]
    /// What the current route involves, counted once per route rather than on every read of `summary`.
    @ObservationIgnored private var counted: (route: NavigationRoute, summary: RouteSummary)?

    /// `planned` is a route an earlier screen found; without it one is asked for.
    init(
        destination: Destination,
        services: AppServices,
        planned: PlannedRoute? = nil,
        campusCrossings: @escaping @Sendable () -> [CampusCrossing] = { CampusCrossings.all }
    ) {
        self.destination = destination
        planner = TripViewModel(services: services)
        distanceSettings = services.distanceSettings
        self.campusCrossings = campusCrossings
        if let planned { planner.use(planned) }
    }

    /// The route found, to hand on so the next screen walks this exact route.
    var plannedRoute: PlannedRoute? { planner.plannedRoute }

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

    /// "About 6 minutes, 450 feet. 3 turns, 2 crosswalks.", in the user's units, read each
    /// time so a change in Settings shows at once.
    var summary: String? {
        guard let route else { return nil }
        if counted?.route != route {
            let crossings = RouteCrossings.along(route, crossings: campusCrossings())
            counted = (route, RouteSummary(route: route, crossings: crossings))
        }
        return counted?.summary.text(distances: distanceSettings.formatter)
    }

    /// Posted once when the route arrives, so the user knows Start is there and what the walk
    /// involves.
    var routeReadyAnnouncement: String? {
        summary.map { "Route ready. \($0)" }
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
}
