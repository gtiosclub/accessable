import Foundation
import Testing
@testable import AccessAble

@MainActor
struct AppServicesTests {
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

    /// The Valhalla servers come from ROUTING_SERVERS, in order, ahead of Apple Maps.
    @Test
    func liveAsksTheConfiguredValhallaServersInOrder() throws {
        let routing = AppServices.live(performance: PerformanceModeMonitor()).routing
        let chain = try #require(((routing as? ReportAwareRoutingService)?.base ?? routing) as? FallbackRoutingService)
        let servers = try #require(chain.primaries as? [ValhallaRoutingService])

        // Shared.xcconfig sets it, and a member's Secrets.xcconfig may change it
        let configured = try #require(Bundle.main.object(forInfoDictionaryKey: "RoutingServers") as? String)
        #expect(!configured.isEmpty && !configured.contains("$("))
        #expect(servers.map(\.endpoint.baseURL) == RoutingConfig.servers.map(\.baseURL))
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
