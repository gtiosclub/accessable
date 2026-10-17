import Foundation

/// Dependency container passed to view models. View models depend on protocols, never concrete services,
/// so each subteam can swap in its implementation without touching anyone else's code.
struct AppServices: Sendable {
    var announcements: any AnnouncementEngineProtocol
    var haptics: any HapticRendering
    var obstacleAlert: any ObstacleAlerting
    var performance: any PerformanceModeProviding
    var scene: any SceneObservationProviding
    var sceneDescriber: any SceneDescribing
    var location: any LocationProvider
    var routing: any RoutingService
    var destinationSearch: any DestinationSearching
    var trip: any TripStateProviding
    var locationContext: any LocationContextProviding
    var commands: any CommandInterpreting

    /// Real services used by the app. Swap each placeholder as the owning subteam ships.
    @MainActor
    static func live(performance: PerformanceModeMonitor) -> AppServices {
        let scene = PlaceholderSceneProvider()      // TODO(CV 1.4): CameraSessionManager + SceneAnalyzer
        let trip = PlaceholderTripProvider()        // TODO(Maps 2.2): TripManager / RouteProgressTracker
        let location = CoreLocationProvider()
        var services = AppServices(
            announcements: PlaceholderAnnouncementEngine(), // TODO(UI 3.3): AnnouncementEngine
            haptics: CoreHapticsRenderer(),                  // TODO(UI 3.2): CoreHapticsRenderer
            obstacleAlert: ObstacleAlertPlayer(),
            performance: performance,
            scene: scene,
            sceneDescriber: scene,                          // TODO(CV 1.3)
            location: location,
            routing: ValhallaRoutingService(),
            destinationSearch: DestinationAutocompleter(region: .georgiaTech),
            trip: trip,
            locationContext: trip,                          // TODO(Maps 2.1)
            commands: FoundationModelCommandInterpreter()
        )
        services.trip = TripManager(
            location: location, routing: services.routing, announcements: services.announcements,
            setBackgroundTracking: { await location.setBackgroundTracking($0) }
        )
        return services
    }

    /// For SwiftUI previews and unit tests.
    @MainActor
    static var preview: AppServices {
        var services = live(performance: PerformanceModeMonitor())
        // Previews and tests must not reach the network or spend the public server's fair-use budget.
        services.routing = PlaceholderRoutingService()
        // A real trip would start GPS tracking and background location from a preview or test.
        services.trip = PlaceholderTripProvider()
        return services
    }
}
