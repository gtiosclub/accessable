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
