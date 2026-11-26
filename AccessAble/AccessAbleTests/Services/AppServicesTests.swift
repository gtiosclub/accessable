import Foundation
import Testing
@testable import AccessAble

@MainActor
struct AppServicesTests {
    @Test func liveCallsNeverSimulateSuccess() {
        let services = AppServices.live(performance: PerformanceModeMonitor())
        #expect(!(services.callSignaling is PlaceholderCallSignaling))
        #expect(!(services.presence is PlaceholderPresenceService))
        #expect(!(services.volunteers is PlaceholderVolunteerDirectory))
        #expect(!(services.incomingCalls is PlaceholderIncomingCalls))
        #expect(services.videoCall is LiveKitVideoCallSession)
    }

    @Test func previewCallDependenciesStayOffline() {
        let services = AppServices.preview
        #expect(services.callSignaling is PlaceholderCallSignaling)
        #expect(services.videoCall is PlaceholderVideoCallSession)
        #expect(services.presence is PlaceholderPresenceService)
        #expect(services.volunteers is PlaceholderVolunteerDirectory)
        #expect(services.incomingCalls is PlaceholderIncomingCalls)
        #expect(services.location is PlaceholderLocationProvider)
        #expect(services.destinationSearch is PlaceholderDestinationSearch)
    }

    @Test func missingWorkerURLFailsBeforeRingingOrAccepting() async {
        let signaling = FirestoreCallSignaling(auth: PlaceholderAuthService(), tokenURL: nil)
        await #expect(throws: CallSignalingError.notConfigured) {
            try await signaling.requestCall(preferring: nil, progress: { _ in })
        }
        await #expect(throws: CallSignalingError.notConfigured) { try await signaling.accept(callID: "fake") }
    }

    @Test func missingFirebaseCannotProvideATicket() async {
        let unavailable = UnavailableCallServices(message: "Firebase isn't configured.")
        await #expect(throws: CallConfigurationError(message: "Firebase isn't configured.")) {
            try await unavailable.requestCall(preferring: nil, progress: { _ in })
        }
    }
    @Test
    func previewNeverRoutesOverTheNetwork() {
        #expect(AppServices.preview.routing is PlaceholderRoutingService)
    }

    /// With Firebase configured, report-aware routing wraps the fallback, so its last try can reach Apple Maps.
    @Test
    func liveFallsBackToAppleMapsWhenValhallaFails() {
        let configured = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil
        let routing = AppServices.live(performance: PerformanceModeMonitor()).routing
        if configured {
            #expect((routing as? ReportAwareRoutingService)?.base is FallbackRoutingService)
        } else {
            #expect(routing is FallbackRoutingService)
        }
    }

    /// Shared.xcconfig's stadia,fossgis, ahead of Apple Maps. Without a Stadia key, as in CI, only FOSSGIS is left.
    @Test
    func liveAsksTheConfiguredValhallaServersInOrder() throws {
        let routing = AppServices.live(performance: PerformanceModeMonitor()).routing
        let chain = try #require(((routing as? ReportAwareRoutingService)?.base ?? routing) as? FallbackRoutingService)
        let servers = try #require(chain.primaries as? [ValhallaRoutingService])

        // Shared.xcconfig sets it, and a member's Secrets.xcconfig may change it
        let configured = try #require(Bundle.main.object(forInfoDictionaryKey: "RoutingServers") as? String)
        #expect(!configured.isEmpty && !configured.contains("$("))
        let fossgis = URL(string: "https://valhalla1.openstreetmap.de")!
        let stadia = URL(string: "https://api.stadiamaps.com")!
        let expected = StadiaConfig.apiKey == nil ? [fossgis] : [stadia, fossgis]
        #expect(servers.map(\.endpoint.baseURL) == expected)
        #expect(chain.fallback is AppleMapsRoutingService)
    }

    @Test
    func liveGuidesTripsWithTripManager() {
        #expect(AppServices.live(performance: PerformanceModeMonitor()).trip is TripManager)
    }

    @Test
    func liveDeliversThroughTheRealEngine() {
        #expect(AppServices.live(performance: PerformanceModeMonitor()).announcements is AnnouncementEngine)
    }

    @Test
    func previewNeverSpeaksAloud() {
        #expect(AppServices.preview.announcements is PlaceholderAnnouncementEngine)
    }

    @Test
    func previewNeverStartsRealTrips() {
        #expect(AppServices.preview.trip is PlaceholderTripProvider)
    }

    @Test
    func previewNeverSignsInToFirebase() {
        #expect(AppServices.preview.auth is PlaceholderAuthService)
    }

    /// The test host has no `GoogleService-Info.plist` unless a developer added one, and must still launch.
    @Test
    func liveFallsBackToThePlaceholderSignInWithoutFirebaseConfig() {
        let configured = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil
        let auth = AppServices.live(performance: PerformanceModeMonitor()).auth
        #expect(configured ? auth is FirebaseAuthService : auth is PlaceholderAuthService)
    }
}
