import CoreLocation
import os

@MainActor
final class CoreLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    
    private nonisolated let authorizationUpdates = Broadcaster<LocationAuthorization>()
    private nonisolated let latestAuthorization = OSAllocatedUnfairLock<LocationAuthorization>(initialState: .notDetermined)
    
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
        let updates = authorizationUpdates.stream()
        let current = latestAuthorization.withLock { $0 }
        
        return AsyncStream { continuation in
            continuation.yield(current)
            let task = Task {
                var last = current
                for await state in updates where state != last {
                    last = state
                    continuation.yield(state)
                }
                continuation.finish()
            }
            continuation.onTermination = {_ in task.cancel()}
        }
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
        latestAuthorization.withLock {$0 = state}
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

