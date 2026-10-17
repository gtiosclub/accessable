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
        let announcements = PlaceholderAnnouncementEngine() // TODO(UI 3.3): AnnouncementEngine
        let scene = liveScene(performance: performance, announcements: announcements)
        let trip = PlaceholderTripProvider()        // TODO(Maps 2.2): TripManager / RouteProgressTracker
        let location = CoreLocationProvider()
        var services = AppServices(
            // The same engine the camera pipeline submits to, so what the UI hears and shows
            // is what CV emitted. A second instance here would receive nothing.
            announcements: announcements,                   // TODO(UI 3.3): AnnouncementEngine
            haptics: CoreHapticsRenderer(),
            obstacleAlert: ObstacleAlertPlayer(),
            performance: performance,
            scene: scene,
            sceneDescriber: scene,
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

    /// The camera pipeline where ARKit world tracking runs; the sample scene elsewhere
    /// (the Simulator, previews).
    private static func liveScene(
        performance: PerformanceModeMonitor,
        announcements: any AnnouncementSink
    ) -> any SceneObservationProviding & SceneDescribing {
        guard ARSessionManager.isSupported else { return PlaceholderSceneProvider() }
        return ARSceneAnalyzer(sessionManager: ARSessionManager(), performance: performance, announcements: announcements)
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
