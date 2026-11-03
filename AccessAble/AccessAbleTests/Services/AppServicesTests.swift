import Testing
@testable import AccessAble

@MainActor
struct AppServicesTests {
    @Test
    func previewNeverRoutesOverTheNetwork() {
        #expect(AppServices.preview.routing is PlaceholderRoutingService)
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
    func previewNeverStartsRealTrips() {
        #expect(AppServices.preview.trip is PlaceholderTripProvider)
    }
}
