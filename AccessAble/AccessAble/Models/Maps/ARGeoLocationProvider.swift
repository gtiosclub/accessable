import Foundation

/// Location readings from ARKit geo-tracking (AR-3): where the camera is once geo-tracking has localized.
struct ARGeoLocationProvider: Sendable {
    let geoTracking: any GeoTrackingProviding

    /// Readings at every accuracy, low included; `FusedLocationProvider` decides which to trust.
    func locationSamples() -> AsyncStream<LocationSample> {
        let updates = geoTracking.geoTrackingUpdates()
        return AsyncStream { continuation in
            let task = Task {
                for await update in updates {
                    if let sample = Self.sample(from: update) { continuation.yield(sample) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Nil until geo-tracking has localized with a known accuracy.
    static func sample(from update: GeoTrackingUpdate) -> LocationSample? {
        guard update.state == .localized, let coordinate = update.coordinate,
              let radius = horizontalAccuracy(update.accuracy)
        else { return nil }
        return LocationSample(coordinate: coordinate, horizontalAccuracy: radius, timestamp: update.timestamp, source: .ar)
    }

    /// Metres. ARKit gives only a grade, so these are cautious guesses until the AR-6 walk measures them. They are
    /// no sharper than a good GPS fix, so a guess doesn't make AR pass gates tuned on GPS that GPS itself would not,
    /// such as the tracker's 10 m for a wrong-way warning or the 20 m trip rerouting wants.
    static func horizontalAccuracy(_ accuracy: GeoTrackingUpdate.Accuracy) -> Double? {
        switch accuracy {
        case .high: 5
        case .medium: 10
        case .low: 20
        case .undetermined: nil
        }
    }
}
