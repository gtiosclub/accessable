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
    /// Lets trips ask the camera for geo-tracking (AR-2); nil where it can't (the sample scene).
    var geoTracking: (any GeoTrackingProviding)?
    /// Whether Apple has geo-tracking imagery here; capped, so the camera never waits long on it.
    var isGeoTrackingAvailableHere: @Sendable () async -> Bool = { await ARSessionManager.isGeoTrackingAvailableHere() }
    var location: any LocationProvider
    var routing: any RoutingService
    var destinationSearch: any DestinationSearching
    var trip: any TripStateProviding
    var tripActivity: any TripActivityClient
    var locationContext: any LocationContextProviding
    var commands: any CommandInterpreting
    var auth: any AuthService
    var reports: any ReportService = PlaceholderReportService()
    var userProfiles: any UserProfileStore = UnconfiguredUserProfileStore()
    var callSafety: any CallSafetyService = UnavailableCallSettings()
    var volunteerSettings: any VolunteerSettingsStore = UnavailableCallSettings()
    var callerSettings = CallerSettings()
    /// False without REPORT-1's Firebase config; the app then runs without accounts, as before.
    var accountsAvailable = false
    /// True once a real report service is wired (REPORT-3); until then the trip screen offers no reporting.
    var reportsAvailable = false
    var landmarks: any LandmarkObserving = PlaceholderLandmarkProvider()
    // Defaults for lightweight initializers; live() explicitly replaces every call dependency.
    var volunteers: any VolunteerDirectory = PlaceholderVolunteerDirectory()
    var presence: any PresenceService = PlaceholderPresenceService()
    var callSignaling: any CallSignaling = PlaceholderCallSignaling()
    var incomingCalls: any IncomingCallProviding = PlaceholderIncomingCalls()
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
    /// The trip in progress, kept for resuming after the app closes; nil where trips aren't kept.
    var savedTrips: SavedTripStore?

    /// Real services used by the app. Swap each placeholder as the owning subteam ships.
    @MainActor
    static func live(performance: PerformanceModeMonitor) -> AppServices {
        // One renderer, so the engine's haptics and anyone else's replace each other rather than overlap.
        let haptics = CoreHapticsRenderer()
        let callerSettings = CallerSettings()
        let announcements = AnnouncementEngine(speech: SpeechOutput(), haptics: haptics, callSettings: callerSettings)
        let askAISettings = AskAISettings()
        let alertSettings = AlertSettings()
        let distanceSettings = DistanceSettings()
        let scene = liveScene(
            performance: performance, announcements: announcements,
            askAISettings: askAISettings, alertSettings: alertSettings
        )
        let trip = PlaceholderTripProvider()        // TODO(Maps 2.2): TripManager / RouteProgressTracker
        let gps = CoreLocationProvider()
        let geoTracking = scene as? any GeoTrackingProviding
        // AR readings only flow while a trip has the camera geo-tracking (AR-2)
        let location = FusedLocationProvider(gps: gps, geoTracking: geoTracking)
        var services = AppServices(
            // The same engine the camera pipeline submits to, so what the UI hears and shows
            // is what CV emitted. A second instance here would receive nothing.
            announcements: announcements,
            haptics: haptics,
            performance: performance,
            scene: scene,
            sceneDescriber: scene,
            location: location,
            // Apple Maps when Valhalla fails or is slow; its routes don't know about stairs, so the user is told
            routing: FallbackRoutingService(primary: ValhallaRoutingService(endpoint: .live), fallback: AppleMapsRoutingService()),
            destinationSearch: DestinationAutocompleter(region: .georgiaTech),
            trip: trip,
            tripActivity: ActivityKitTripActivityClient(),
            // GPS alone: "where am I" is asked outside trips too, where the camera doesn't geo-track
            locationContext: LocationDescriber(location: gps, distances: distanceSettings),
            commands: FoundationModelCommandInterpreter(),
            auth: FirebaseApp.app() != nil ? FirebaseAuthService() : PlaceholderAuthService(signedIn: false),
            callerSettings: callerSettings,
            askAISettings: askAISettings,
            alertSettings: alertSettings,
            distanceSettings: distanceSettings
        )
        let unavailable = UnavailableCallServices(message: "Calls require the shared Firebase configuration on this phone.")
        services.volunteers = unavailable
        services.presence = unavailable
        services.callSignaling = unavailable
        services.incomingCalls = unavailable
        services.geoTracking = geoTracking
        if let analyzer = scene as? ARSceneAnalyzer {
            let perception = analyzer.perception
            services.landmarks = CameraLandmarkProvider(
                scene: analyzer,
                setReadsText: { perception.setReadsLandmarkText($0) },
                // Find and Read speak the signs SignInterpreter knows, so Maps doesn't name them again
                isAnnouncedByCamera: { perception.mode.announcesSigns && SignInterpreter.interpret($0) != nil }
            )
        }
        if FirebaseApp.app() != nil {
            services.reports = FirestoreReportService(auth: services.auth)
            services.reportsAvailable = true
            services.routing = ReportAwareRoutingService(base: services.routing, reports: services.reports)
            services.userProfiles = FirestoreUserProfileStore()
            services.callSafety = FirestoreCallSafety(auth: services.auth)
            services.volunteerSettings = FirestoreVolunteerSettings(auth: services.auth)
            services.volunteers = FirestoreVolunteerDirectory()
            services.presence = FirestorePresenceService(auth: services.auth, profiles: services.userProfiles)
            services.accountsAvailable = true
            if let tokenURL = LiveKitConfig.callTokenURL {
                services.callSignaling = FirestoreCallSignaling(auth: services.auth, tokenURL: tokenURL)
                services.incomingCalls = FirestoreIncomingCalls(presence: services.presence)
            } else {
                // Without the token Worker nobody can place or accept a call, so a volunteer can't go
                // Online either: they would be rung for calls whose Accept can only fail.
                let unconfigured = UnavailableCallServices(
                    message: CallSignalingError.notConfigured.localizedDescription)
                services.presence = unconfigured
                services.callSignaling = unconfigured
                services.incomingCalls = unconfigured
            }
        }
        services.savedTrips = SavedTripStore()
        services.trip = TripManager(
            location: location, routing: services.routing, announcements: services.announcements,
            reports: services.reportsAvailable ? services.reports : nil,
            currentUserID: { [auth = services.auth] in await auth.currentUser()?.id },
            landmarks: services.landmarks,
            setTripTracking: { await gps.setTripTracking($0) },
            distances: distanceSettings,
            recorder: services.tripRecorder,
            savedTrips: services.savedTrips
        )

        let analyzer = scene as? ARSceneAnalyzer
        services.videoCall = LiveKitVideoCallSession(
            auth: services.auth,
            pauseCamera: { try analyzer?.pauseForCall() },
            resumeCamera: { try analyzer?.resumeAfterCall($0) }
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

    /// How trips open the camera: the trip screen and `TripCameraCoordinator` both go through it.
    var tripCamera: TripCamera {
        TripCamera(scene: scene, geoTracking: geoTracking, isGeoTrackingAvailableHere: isGeoTrackingAvailableHere)
    }

    /// For SwiftUI previews and unit tests.
    @MainActor
    static var preview: AppServices {
        let scene = PlaceholderSceneProvider()
        let callerSettings = CallerSettings()
        // Construct previews directly: never initialize Firebase listeners, LiveKit, GPS or speech.
        var services = AppServices(
            announcements: PlaceholderAnnouncementEngine(callSettings: callerSettings), haptics: PlaceholderHaptics(),
            performance: PerformanceModeMonitor(), scene: scene, sceneDescriber: scene,
            location: PlaceholderLocationProvider(), routing: PlaceholderRoutingService(),
            destinationSearch: PlaceholderDestinationSearch(), trip: PlaceholderTripProvider(),
            tripActivity: PlaceholderTripActivityClient(), locationContext: PlaceholderTripProvider(),
            commands: FoundationModelCommandInterpreter(), auth: PlaceholderAuthService()
        )
        services.distanceSettings = DistanceSettings(units: .metres)
        services.callerSettings = callerSettings
        services.callSafety = PlaceholderCallSafety()
        services.volunteerSettings = PlaceholderVolunteerSettings()
        services.userProfiles = PlaceholderUserProfileStore(profiles: [
            UserProfile(userID: PlaceholderAuthService.sampleUser.id, role: .caller,
                        displayName: "Preview caller", languages: ["English"], createdAt: .now)
        ])
        services.volunteers = PlaceholderVolunteerDirectory()
        services.presence = PlaceholderPresenceService()
        services.videoCall = PlaceholderVideoCallSession()
        services.callSignaling = PlaceholderCallSignaling()
        services.incomingCalls = PlaceholderIncomingCalls()
        // Reports stay in memory, so previews and tests can report a problem.
        services.reports = PlaceholderReportService()
        services.reportsAvailable = true
        return services
    }
}
