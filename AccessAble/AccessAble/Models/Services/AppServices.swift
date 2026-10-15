import Foundation

/// Dependency container passed to view models. View models depend on protocols, never concrete services,
/// so each subteam can swap in its implementation without touching anyone else's code.
struct AppServices: Sendable {
    var announcements: any AnnouncementEngineProtocol
    var haptics: any HapticRendering
    var performance: any PerformanceModeProviding
    var scene: any SceneObservationProviding
    var sceneDescriber: any SceneDescribing
    var trip: any TripStateProviding
    var locationContext: any LocationContextProviding

    /// Real services used by the app. Swap each placeholder as the owning subteam ships.
    @MainActor
    static func live(performance: PerformanceModeMonitor) -> AppServices {
        let announcements = PlaceholderAnnouncementEngine() // TODO(UI 3.3): AnnouncementEngine
        let scene = liveScene(performance: performance, announcements: announcements)
        let trip = PlaceholderTripProvider()        // TODO(Maps 2.2): TripManager / RouteProgressTracker
        return AppServices(
            announcements: announcements,
            haptics: PlaceholderHaptics(),                  // TODO(UI 3.2): CoreHapticsRenderer
            performance: performance,
            scene: scene,
            sceneDescriber: scene,
            trip: trip,
            locationContext: trip                           // TODO(Maps 2.1)
        )
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
    static var preview: AppServices { live(performance: PerformanceModeMonitor()) }
}
