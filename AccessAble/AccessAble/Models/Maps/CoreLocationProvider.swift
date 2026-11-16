import CoreLocation
import os

private let log = Logger(subsystem: "AccessAble", category: "Location")

/// How Core Location is set up, which differs while a trip is guiding.
struct LocationTuning: Equatable {
    var desiredAccuracy: CLLocationAccuracy
    var activityType: CLActivityType
    var allowsBackgroundUpdates: Bool
    var pausesAutomatically: Bool

    /// Browsing the map needs less than guidance does, and the best accuracy costs battery.
    static let browsing = LocationTuning(desiredAccuracy: kCLLocationAccuracyBest, activityType: .fitness,
                                         allowsBackgroundUpdates: false, pausesAutomatically: true)
    /// Guidance needs every metre: the tracker ignores fixes rougher than 25 m. Updates keep coming with the
    /// screen locked, and never pause: waiting at a crosswalk with the phone in a pocket could otherwise stop
    /// them for the rest of the walk.
    static let trip = LocationTuning(desiredAccuracy: kCLLocationAccuracyBestForNavigation,
                                     activityType: .otherNavigation, allowsBackgroundUpdates: true,
                                     pausesAutomatically: false)
}

@MainActor
final class CoreLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    private nonisolated let authorizationUpdates = Broadcaster<LocationAuthorization>(replaysLatest: true)

    private var lastAuthorization: LocationAuthorization?
    
    private nonisolated let locationUpdates = Broadcaster<LocationSample>()
    private var locationSubscriberCount = 0
    /// Metres, from the latest fix; logged when the tuning changes, to compare trip accuracy with browsing.
    private var lastAccuracy: Double?

    override init() {
        super.init()
        manager.delegate = self
        apply(.browsing)
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
            // the add and remove run in separate tasks, so a quick unsubscribe can briefly count wrong; the count
            // settles once both have run
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.locationSubscriberRemoved()}
            }
        }
    }

    /// Navigation-grade accuracy and fixes with the screen locked, for an active trip only: the Trip screen's and
    /// the debug view's own subscriptions stay open in the background, so leaving this on would track the user,
    /// and drain the battery, whenever the app is open.
    func setTripTracking(_ on: Bool) {
        let accuracy = lastAccuracy.map { "\($0.formatted(.number.precision(.fractionLength(0)))) m" } ?? "none yet"
        log.info("Trip tracking \(on ? "on" : "off", privacy: .public); last fix accuracy \(accuracy, privacy: .public)")
        apply(on ? .trip : .browsing)
    }

    private func apply(_ tuning: LocationTuning) {
        manager.desiredAccuracy = tuning.desiredAccuracy
        manager.activityType = tuning.activityType
        manager.allowsBackgroundLocationUpdates = tuning.allowsBackgroundUpdates
        manager.pausesLocationUpdatesAutomatically = tuning.pausesAutomatically
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
        // Core Location calls the delegate on the main thread, as above.
        MainActor.assumeIsolated {
            if let accuracy = locations.last?.horizontalAccuracy, accuracy >= 0 { lastAccuracy = accuracy }
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
