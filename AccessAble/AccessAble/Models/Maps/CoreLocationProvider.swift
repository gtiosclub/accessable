import CoreLocation

@MainActor
final class CoreLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    private nonisolated let authorizationUpdates = Broadcaster<LocationAuthorization>(replaysLatest: true)

    private var lastAuthorization: LocationAuthorization?

    override init() {
        super.init()
        manager.delegate = self
        publishAuthorization()
    }

    nonisolated func locationSamples() -> AsyncStream<LocationSample> {
        AsyncStream { continuation in continuation.finish() }
    }

    nonisolated func headingSamples() -> AsyncStream<HeadingSample> {
        AsyncStream { continuation in continuation.finish() }
    }

    nonisolated func authorizationStates() -> AsyncStream<LocationAuthorization> {
        authorizationUpdates.stream()
    }

    nonisolated func requestAuthorization() async {
        await askForPermission()
    }

    private func askForPermission() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Core Location calls the delegate on the thread that created the manager, which is the main
        // thread because this class is @MainActor.
        MainActor.assumeIsolated {
            publishAuthorization()
        }
    }

    private func publishAuthorization() {
        let state = LocationAuthorization(status: manager.authorizationStatus, accuracy: manager.accuracyAuthorization)
        guard state != lastAuthorization else { return }
        lastAuthorization = state
        authorizationUpdates.send(state)
    }
}
