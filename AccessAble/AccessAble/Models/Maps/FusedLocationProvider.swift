import Foundation

/// GPS, sharpened by geo-tracking whenever it is locked on (AR-3). Outside trips the camera doesn't geo-track, so
/// this is GPS alone. Each reading's `source` says which it is.
struct FusedLocationProvider: LocationProvider {
    let gps: any LocationProvider
    /// Nil where there is no AR camera (the Simulator, previews).
    let geoTracking: (any GeoTrackingProviding)?

    func locationSamples() -> AsyncStream<LocationSample> {
        guard let geoTracking else { return gps.locationSamples() }
        // subscribed here, not in the task, so no reading sent before the task starts is lost
        let gpsSamples = gps.locationSamples()
        let arReadings = ARGeoLocationProvider(geoTracking: geoTracking).readings()
        let (readings, input) = AsyncStream.makeStream(of: LocationFusion.Reading.self)

        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task {
                await withDiscardingTaskGroup { group in
                    group.addTask {
                        for await sample in gpsSamples { input.yield(.gps(sample)) }
                        input.finish()
                    }
                    group.addTask {
                        for await reading in arReadings { input.yield(reading) }
                    }
                    group.addTask {
                        var fusion = LocationFusion()
                        for await reading in readings {
                            if let sample = fusion.receive(reading) { continuation.yield(sample) }
                        }
                        // ends the AR loop too, through onTermination
                        continuation.finish()
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func headingSamples() -> AsyncStream<HeadingSample> { gps.headingSamples() }
    func authorizationStates() -> AsyncStream<LocationAuthorization> { gps.authorizationStates() }
    func requestAuthorization() async { await gps.requestAuthorization() }
}

/// Which reading to pass on: AR while geo-tracking is locked on with medium accuracy or better and agrees with GPS,
/// GPS otherwise. Passing both would make the position jump between them.
struct LocationFusion {
    enum Reading: Equatable, Sendable {
        case gps(LocationSample)
        case ar(LocationSample)
        /// Geo-tracking stopped or lost its lock.
        case arLost
    }

    /// Seconds an AR reading is trusted for. Geo-tracking sends one a second; a gap means the camera stopped.
    static let arLifetime: TimeInterval = 2
    /// Worst AR accuracy trusted, in metres: medium.
    static let arAccuracyLimit = ARGeoLocationProvider.horizontalAccuracy(.medium) ?? 0
    /// Metres beyond GPS's own accuracy that AR may disagree with it; GPS often errs past its stated accuracy.
    static let disagreementAllowance: Double = 20
    /// Seconds a GPS fix counts for checking AR against, and for lending AR readings its speed and course.
    static let gpsFreshness: TimeInterval = 5

    private var trustedARUntil: Date?
    private var latestGPS: LocationSample?

    mutating func receive(_ reading: Reading) -> LocationSample? {
        switch reading {
        case .gps(let sample):
            latestGPS = sample
            if let trustedARUntil, sample.timestamp <= trustedARUntil { return nil }
            return sample
        case .ar(var sample):
            guard sample.horizontalAccuracy <= Self.arAccuracyLimit, agreesWithGPS(sample) else {
                trustedARUntil = nil
                return nil
            }
            trustedARUntil = sample.timestamp.addingTimeInterval(Self.arLifetime)
            // geo-tracking has no speed or course, and walking-direction heading needs them
            if let gps = freshGPS(at: sample.timestamp) {
                sample.speed = gps.speed
                sample.speedAccuracy = gps.speedAccuracy
                sample.course = gps.course
                sample.courseAccuracy = gps.courseAccuracy
            }
            return sample
        case .arLost:
            trustedARUntil = nil
            return nil
        }
    }

    /// Geo-tracking can lock on to the wrong street; a fresh GPS fix catches that.
    private func agreesWithGPS(_ sample: LocationSample) -> Bool {
        guard let gps = freshGPS(at: sample.timestamp) else { return true }
        return GeoMath.distance(from: sample.coordinate, to: gps.coordinate)
            <= gps.horizontalAccuracy + Self.disagreementAllowance
    }

    private func freshGPS(at time: Date) -> LocationSample? {
        guard let latestGPS, abs(time.timeIntervalSince(latestGPS.timestamp)) <= Self.gpsFreshness else { return nil }
        return latestGPS
    }
}
