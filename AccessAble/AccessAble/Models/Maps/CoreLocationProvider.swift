import CoreLocation

@MainActor
final class CoreLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    nonisolated func locationSamples() -> AsyncStream<LocationSample> {
        AsyncStream { continuation in continuation.finish() }
    }

    nonisolated func headingSamples() -> AsyncStream<HeadingSample> {
        AsyncStream { continuation in continuation.finish() }
    }

    nonisolated func authorizationStates() -> AsyncStream<LocationAuthorization> {
        AsyncStream { continuation in continuation.finish() }
    }

    nonisolated func requestAuthorization() async {
        await askForPermission()
    }

    private func askForPermission() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }
}
