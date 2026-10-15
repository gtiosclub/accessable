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
        guard manager.authorizationStatus == .notDetermined else {return}
        manager.requestWhenInUseAuthorization()
    }
    
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            publishAuthorization()
        }
    }
    
    private func publishAuthorization() {
        let state = currentAuthorization()
        guard state != lastAuthorization else {return}
        lastAuthorization = state
        authorizationUpdates.send(state)
    }
    
    private func currentAuthorization() -> LocationAuthorization {
        switch manager.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorizedWhenInUse, .authorizedAlways:
            return .authorized(preciseAccuracy: manager.accuracyAuthorization == .fullAccuracy)
        @unknown default:
            return .denied
        }
    }
    
}

