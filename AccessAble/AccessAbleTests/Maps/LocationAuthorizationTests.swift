import CoreLocation
import Testing
@testable import AccessAble

struct LocationAuthorizationTests {
    @Test(arguments: [
        (CLAuthorizationStatus.notDetermined, CLAccuracyAuthorization.fullAccuracy, LocationAuthorization.notDetermined),
        (.notDetermined, .reducedAccuracy, .notDetermined),
        (.restricted, .fullAccuracy, .restricted),
        (.restricted, .reducedAccuracy, .restricted),
        (.denied, .fullAccuracy, .denied),
        (.denied, .reducedAccuracy, .denied),
        (.authorizedWhenInUse, .fullAccuracy, .authorized(preciseAccuracy: true)),
        (.authorizedWhenInUse, .reducedAccuracy, .authorized(preciseAccuracy: false)),
        (.authorizedAlways, .fullAccuracy, .authorized(preciseAccuracy: true)),
        (.authorizedAlways, .reducedAccuracy, .authorized(preciseAccuracy: false)),
    ])
    func mapsCoreLocationStatus(
        _ status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization, expected: LocationAuthorization
    ) {
        #expect(LocationAuthorization(status: status, accuracy: accuracy) == expected)
    }
}
