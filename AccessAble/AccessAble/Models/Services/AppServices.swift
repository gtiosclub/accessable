import Foundation

/// Dependency container passed to view models. View models depend on protocols, never concrete services,
/// so each subteam can swap in its implementation without touching anyone else's code.
struct AppServices: Sendable {
    var announcements: any AnnouncementEngineProtocol
    var haptics: any HapticRendering
    var performance: any PerformanceModeProviding
    var scene: any SceneObservationProviding
    var sceneDescriber: any SceneDescribing
    var location: any LocationProvider
    var routing: any RoutingService
    var destinationSearch: any DestinationSearching
    var trip: any TripStateProviding
    var locationContext: any LocationContextProviding

    /// Real services used by the app. Swap each placeholder as the owning subteam ships.
    @MainActor
    static func live(performance: PerformanceModeMonitor) -> AppServices {
        let scene = PlaceholderSceneProvider()      // TODO(CV 1.4): CameraSessionManager + SceneAnalyzer
        let trip = PlaceholderTripProvider()        // TODO(Maps 2.2): TripManager / RouteProgressTracker
        return AppServices(
            announcements: PlaceholderAnnouncementEngine(), // TODO(UI 3.3): AnnouncementEngine
            haptics: PlaceholderHaptics(),                  // TODO(UI 3.2): CoreHapticsRenderer
            performance: performance,
            scene: scene,
            sceneDescriber: scene,                          // TODO(CV 1.3)
            location: PlaceholderLocationProvider(),        // TODO(Maps 2.1): CoreLocationProvider
            routing: PlaceholderRoutingService(),           // TODO(Maps 2.2): ValhallaRoutingService
            destinationSearch: DestinationAutocompleter(),
            trip: trip,
            locationContext: trip                           // TODO(Maps 2.1)
        )
    }

    /// For SwiftUI previews and unit tests.
    @MainActor
    static var preview: AppServices { live(performance: PerformanceModeMonitor()) }
}
