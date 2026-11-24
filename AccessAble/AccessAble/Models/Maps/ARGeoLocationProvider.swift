import Foundation

/// Location readings from ARKit geo-tracking (AR-3): where the camera is once geo-tracking has localized.
struct ARGeoLocationProvider: Sendable {
    let geoTracking: any GeoTrackingProviding

    /// Readings at every accuracy, low included, and each loss of the lock; `LocationFusion` decides which to trust.
    func readings() -> AsyncStream<LocationFusion.Reading> {
        let updates = geoTracking.geoTrackingUpdates()
        return AsyncStream { continuation in
            let task = Task {
                for await update in updates { continuation.yield(Self.reading(from: update)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `.arLost` for any update without a usable position: geo-tracking stopped, is still localizing or lost its
    /// lock, so AR mustn't be trusted until it localizes again.
    static func reading(from update: GeoTrackingUpdate) -> LocationFusion.Reading {
        sample(from: update).map { .ar($0) } ?? .arLost
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
