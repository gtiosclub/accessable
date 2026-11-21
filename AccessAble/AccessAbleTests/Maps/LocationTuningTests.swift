import CoreLocation
import Testing
@testable import AccessAble

struct LocationTuningTests {
    @Test
    func tripAsksForNavigationAccuracyAndKeepsRunningInThePocket() {
        let trip = LocationTuning.trip
        #expect(trip.desiredAccuracy == kCLLocationAccuracyBestForNavigation)
        #expect(trip.activityType == .otherNavigation)
        #expect(trip.allowsBackgroundUpdates)
        #expect(!trip.pausesAutomatically)
    }

    @Test
    func browsingSavesBatteryAndStaysInTheForeground() {
        let browsing = LocationTuning.browsing
        #expect(browsing.desiredAccuracy == kCLLocationAccuracyBest)
        #expect(browsing.activityType == .fitness)
        #expect(!browsing.allowsBackgroundUpdates)
        #expect(browsing.pausesAutomatically)
    }
}
