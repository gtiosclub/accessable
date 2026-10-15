import CoreLocation

@MainActor
final class CoreLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    private nonisolated let authorizationUpdates = Broadcaster<LocationAuthorization>(replaysLatest: true)

    private var lastAuthorization: LocationAuthorization?
    
    private nonisolated let locationUpdates = Broadcaster<LocationSample>()
    private var locationSubscriberCount = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        publishAuthorization()
    }

    nonisolated func locationSamples() -> AsyncStream<LocationSample> {
        let samples = locationUpdates.stream()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) {continuation in
            let task = Task {
                await self.locationSubscriberAdded()
                for await sample in samples {
                    continuation.yield(sample)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.locationSubscriberRemoved()}
            }
        }
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
    
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            if let sample = LocationSample(location) {
                locationUpdates.send(sample)
            }
        }
    }

    private func publishAuthorization() {
        let state = LocationAuthorization(status: manager.authorizationStatus, accuracy: manager.accuracyAuthorization)
        guard state != lastAuthorization else { return }
        lastAuthorization = state
        authorizationUpdates.send(state)
        updateLocationTracking()
    }
    
    private func locationSubscriberAdded() {
        locationSubscriberCount += 1
        updateLocationTracking()
    }
    
    private func locationSubscriberRemoved() {
        locationSubscriberCount -= 1
        updateLocationTracking()
    }
    
    private func updateLocationTracking() {
        if locationSubscriberCount > 0, case .authorized? = lastAuthorization {
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
        }
    }
}
