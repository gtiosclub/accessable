import Foundation
import FirebaseCore

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
    var tripActivity: any TripActivityClient
    var locationContext: any LocationContextProviding
    var commands: any CommandInterpreting
    var auth: any AuthService
    var userProfiles: any UserProfileStore = UnconfiguredUserProfileStore()
    // TODO(CV LAND-1): ARSceneAnalyzer once it emits landmarks
    var landmarks: any LandmarkObserving = PlaceholderLandmarkProvider()
    // TODO(MATCH-x): replace these four placeholders with the real call services.
    var volunteers: any VolunteerDirectory = PlaceholderVolunteerDirectory()
    var presence: any PresenceService = PlaceholderPresenceService()
    var callSignaling: any CallSignaling = PlaceholderCallSignaling()
    var videoCall: any VideoCallSession = PlaceholderVideoCallSession()
    /// The user's Ask AI ranking (T23), read by Ask AI per question. AppViewModel keeps it
    /// in step with the profile.
    var askAISettings = AskAISettings()
    /// What the camera warns about, read by the pipeline every frame. AppViewModel keeps it
    /// in step with the profile.
    var alertSettings = AlertSettings()
    /// Feet or metres for the trip, search and "where am I". AppViewModel keeps it in step with
    /// the profile.
    var distanceSettings = DistanceSettings()
    /// Field-test recording of trips, off until turned on in Developer Tools.
    var tripRecorder = TripRecorder()

    /// Real services used by the app. Swap each placeholder as the owning subteam ships.
    @MainActor
    static func live(performance: PerformanceModeMonitor) -> AppServices {
        // One renderer, so the engine's haptics and anyone else's replace each other rather than overlap.
        let haptics = CoreHapticsRenderer()
        let announcements = AnnouncementEngine(speech: SpeechOutput(), haptics: haptics)
        let askAISettings = AskAISettings()
        let alertSettings = AlertSettings()
        let distanceSettings = DistanceSettings()
        let scene = liveScene(
            performance: performance, announcements: announcements,
            askAISettings: askAISettings, alertSettings: alertSettings
        )
        let trip = PlaceholderTripProvider()        // TODO(Maps 2.2): TripManager / RouteProgressTracker
        let location = CoreLocationProvider()
        var services = AppServices(
            // The same engine the camera pipeline submits to, so what the UI hears and shows
            // is what CV emitted. A second instance here would receive nothing.
            announcements: announcements,
            haptics: haptics,
            performance: performance,
            scene: scene,
            sceneDescriber: scene,
            location: location,
            routing: ValhallaRoutingService(),
            destinationSearch: DestinationAutocompleter(region: .georgiaTech),
            trip: trip,
            tripActivity: ActivityKitTripActivityClient(),
            locationContext: LocationDescriber(location: location, distances: distanceSettings),
            commands: FoundationModelCommandInterpreter(),
            auth: FirebaseApp.app() != nil ? FirebaseAuthService() : PlaceholderAuthService(signedIn: false),
            askAISettings: askAISettings,
            alertSettings: alertSettings,
            distanceSettings: distanceSettings
        )
        if FirebaseApp.app() != nil {
            services.userProfiles = FirestoreUserProfileStore()
        }
        services.trip = TripManager(
            location: location, routing: services.routing, announcements: services.announcements,
            landmarks: services.landmarks,
            setTripTracking: { await location.setTripTracking($0) },
            distances: distanceSettings,
            recorder: services.tripRecorder
        )
        return services
    }

    /// The camera pipeline where ARKit world tracking runs; the sample scene elsewhere
    /// (the Simulator, previews).
    @MainActor
    private static func liveScene(
        performance: PerformanceModeMonitor,
        announcements: any AnnouncementSink,
        askAISettings: AskAISettings,
        alertSettings: AlertSettings
    ) -> any SceneObservationProviding & SceneDescribing {
        guard ARSessionManager.isSupported else { return PlaceholderSceneProvider() }
        return ARSceneAnalyzer(
            sessionManager: ARSessionManager(),
            perception: ScenePerception(alertSettings: alertSettings),
            performance: performance,
            announcements: announcements,
            askAI: AskAI(responder: RuledAskAIResponder(settings: askAISettings)), // T23 order, T24 rules
            steering: SteeringTones()
        )
    }

    /// For SwiftUI previews and unit tests.
    @MainActor
    static var preview: AppServices {
        var services = live(performance: PerformanceModeMonitor())
        // Nor speak aloud: tests build many of these at once, and real speech from several of them has frozen
        // the whole test run inside the system's speech framework.
        services.announcements = PlaceholderAnnouncementEngine()
        // Previews and tests must not reach the network or spend the public server's fair-use budget.
        services.routing = PlaceholderRoutingService()
        // A real trip would start GPS tracking and background location from a preview or test.
        services.trip = PlaceholderTripProvider()
        // Nor put a trip on the simulator's lock screen.
        services.tripActivity = PlaceholderTripActivityClient()
        // Nor wait on GPS and Apple Maps for "where am I".
        services.locationContext = PlaceholderTripProvider()
        // Wording that doesn't change with the simulator's region.
        services.distanceSettings = DistanceSettings(units: .metres)
        // Nor sign in to the real Firebase project.
        services.auth = PlaceholderAuthService()
        services.userProfiles = PlaceholderUserProfileStore(profiles: [
            UserProfile(userID: PlaceholderAuthService.sampleUser.id, role: .caller,
                        displayName: "Preview caller", languages: ["English"], createdAt: .now)
        ])
        return services
    }
}
