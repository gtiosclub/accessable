import Foundation

/// GPS, sharpened by geo-tracking whenever it is locked on (AR-3). Outside trips the camera doesn't geo-track, so
/// this is GPS alone. Each reading's `source` says which it is.
struct FusedLocationProvider: LocationProvider {
    let gps: any LocationProvider
    /// Nil where there is no AR camera (the Simulator, previews).
    let geoTracking: (any GeoTrackingProviding)?

    func locationSamples() -> AsyncStream<LocationSample> {
        guard let geoTracking else { return gps.locationSamples() }
        return Self.merged([
            gps.locationSamples().relayed { LocationFusion.Reading.gps($0) },
            ARGeoLocationProvider(geoTracking: geoTracking).locationSamples().relayed { .ar($0) },
        ]) {
            var fusion = LocationFusion()
            return { fusion.receive($0) }
        }
    }

    /// The compass, plus the camera's heading while geo-tracking is locked on (AR-4). A heading is only as right as
    /// the lock, so it comes through only with a position `LocationFusion` trusts.
    func headingSamples() -> AsyncStream<HeadingSample> {
        guard let geoTracking else { return gps.headingSamples() }
        return Self.merged([
            gps.headingSamples().relayed { HeadingReading.compass($0) },
            gps.locationSamples().relayed { .gps($0) },
            geoTracking.geoTrackingUpdates().relayed { .ar($0) },
        ]) {
            var fusion = LocationFusion()
            return { reading in
                switch reading {
                case .compass(let sample):
                    return sample
                case .gps(let sample):
                    _ = fusion.receive(.gps(sample))
                    return nil
                case .ar(let update):
                    guard let location = ARGeoLocationProvider.sample(from: update),
                          fusion.receive(.ar(location)) != nil
                    else { return nil }
                    return ARGeoLocationProvider.headingSample(from: update)
                }
            }
        }
    }

    private enum HeadingReading: Sendable {
        case compass(HeadingSample)
        case gps(LocationSample)
        case ar(GeoTrackingUpdate)
    }

    /// Hands readings from every source to one handler in arrival order, and passes on what it returns. Ends when
    /// any source ends.
    private static func merged<Reading: Sendable, Output: Sendable>(
        _ sources: [AsyncStream<Reading>],
        handler makeHandler: @escaping @Sendable () -> (Reading) -> Output?
    ) -> AsyncStream<Output> {
        let (readings, input) = AsyncStream.makeStream(of: Reading.self)
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task {
                await withDiscardingTaskGroup { group in
                    for source in sources {
                        group.addTask {
                            for await reading in source { input.yield(reading) }
                            input.finish()
                        }
                    }
                    group.addTask {
                        let handle = makeHandler()
                        for await reading in readings {
                            if let output = handle(reading) { continuation.yield(output) }
                        }
                        // ends the other loops too, through onTermination
                        continuation.finish()
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func authorizationStates() -> AsyncStream<LocationAuthorization> { gps.authorizationStates() }
    func requestAuthorization() async { await gps.requestAuthorization() }
}

/// Which reading to pass on: AR while geo-tracking is locked on with medium accuracy or better and agrees with GPS,
/// GPS otherwise. Passing both would make the position jump between them.
struct LocationFusion {
    enum Reading: Sendable {
        case gps(LocationSample)
        case ar(LocationSample)
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

private extension AsyncStream {
    /// `map`, kept an `AsyncStream` so streams of different readings can be merged.
    func relayed<T: Sendable>(_ transform: @escaping @Sendable (Element) -> T) -> AsyncStream<T> where Element: Sendable {
        AsyncStream<T> { continuation in
            let task = Task {
                for await element in self { continuation.yield(transform(element)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
