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

    /// Nil until geo-tracking has localized with a known accuracy, or while the camera points almost straight up or
    /// down.
    static func headingSample(from update: GeoTrackingUpdate) -> HeadingSample? {
        guard update.state == .localized, let heading = update.heading,
              let accuracy = headingAccuracy(update.accuracy)
        else { return nil }
        return HeadingSample(trueHeading: heading, magneticHeading: heading, accuracy: accuracy,
                             timestamp: update.timestamp, source: .ar)
    }

    /// Degrees. A guess from the grade, like `horizontalAccuracy`; low is past what `HeadingEstimator` trusts.
    static func headingAccuracy(_ accuracy: GeoTrackingUpdate.Accuracy) -> Double? {
        switch accuracy {
        case .high: 5
        case .medium: 10
        case .low: 30
        case .undetermined: nil
        }
    }

    /// Metres. ARKit gives only a grade, so these are cautious guesses until the AR-6 walk measures them.
    static func horizontalAccuracy(_ accuracy: GeoTrackingUpdate.Accuracy) -> Double? {
        switch accuracy {
        case .high: 3
        case .medium: 8
        case .low: 20
        case .undetermined: nil
        }
    }
}
