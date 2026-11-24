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

/// Which reading to pass on: AR once geo-tracking has stayed locked on and agreed with GPS for a while, GPS
/// otherwise. Passing both would make the position jump between them, and so would judging each AR reading alone,
/// since one in a few flickers past a limit; so switching to AR takes a run of good readings, and switching back a
/// clear failure.
///
/// - Into AR: `arEntryReadings` qualifying readings in a row over at least `arEntrySpan`. A reading qualifies when it
///   is `arAccuracyLimit` or better and agrees with a fresh GPS fix. Without fresh GPS nothing would catch a lock on
///   the wrong street, so none qualifies.
/// - On AR: each reading `arAccuracyLimit` or better that agrees with GPS extends trust by `arLifetime`. GPS going
///   stale doesn't end it, since the lock was checked against GPS on the way in.
/// - Back to GPS at once when a reading disagrees with fresh GPS or geo-tracking loses its lock, after
///   `arCoarseReadingsToLeave` too-coarse readings in a row, or when `arLifetime` passes with no reading that extends
///   it. Coming back to AR takes a whole new run.
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
    /// Seconds a GPS fix counts for checking AR against.
    static let gpsFreshness: TimeInterval = 5
    /// Qualifying AR readings in a row that switch to AR. At geo-tracking's one a second, about `arEntrySpan`.
    static let arEntryReadings = 3
    /// Seconds from the first to the last reading of the run that switches to AR, so a burst can't switch alone.
    static let arEntrySpan: TimeInterval = 2
    /// Too-coarse AR readings in a row that switch back to GPS. One, as a grade flickering to low gives, doesn't.
    static let arCoarseReadingsToLeave = 2

    private var latestGPS: LocationSample?
    /// While AR is passed on: until when, unless a reading extends it.
    private var trustedARUntil: Date?
    /// The run of qualifying readings toward switching to AR.
    private var entryRun: (since: Date, count: Int)?
    private var coarseReadings = 0

    mutating func receive(_ reading: Reading) -> LocationSample? {
        switch reading {
        case .gps(let sample):
            latestGPS = sample
            if let trustedARUntil {
                if sample.timestamp <= trustedARUntil { return nil }
                leaveAR()
            }
            return sample
        case .ar(var sample):
            if let trustedARUntil, sample.timestamp > trustedARUntil { leaveAR() }
            let gps = freshGPS(at: sample.timestamp)
            guard sample.horizontalAccuracy <= Self.arAccuracyLimit else {
                entryRun = nil
                coarseReadings += 1
                if coarseReadings >= Self.arCoarseReadingsToLeave { leaveAR() }
                return nil
            }
            coarseReadings = 0
            // geo-tracking can lock on to the wrong street; a fresh GPS fix catches that
            if let gps, !agrees(sample, with: gps) {
                leaveAR()
                return nil
            }
            if trustedARUntil == nil {
                guard gps != nil else {
                    entryRun = nil
                    return nil
                }
                let run = entryRun.map { (since: $0.since, count: $0.count + 1) } ?? (since: sample.timestamp, count: 1)
                guard run.count >= Self.arEntryReadings,
                      sample.timestamp.timeIntervalSince(run.since) >= Self.arEntrySpan else {
                    entryRun = run
                    return nil
                }
                entryRun = nil
            }
            trustedARUntil = sample.timestamp.addingTimeInterval(Self.arLifetime)
            // geo-tracking has no speed or course, and walking-direction heading needs them; an older fix's may be from
            // before the user turned
            if let gps, abs(sample.timestamp.timeIntervalSince(gps.timestamp)) <= HeadingEstimator.maximumSampleAge {
                sample.speed = gps.speed
                sample.speedAccuracy = gps.speedAccuracy
                sample.course = gps.course
                sample.courseAccuracy = gps.courseAccuracy
            }
            return sample
        case .arLost:
            leaveAR()
            return nil
        }
    }

    private mutating func leaveAR() {
        trustedARUntil = nil
        entryRun = nil
        coarseReadings = 0
    }

    private func agrees(_ sample: LocationSample, with gps: LocationSample) -> Bool {
        GeoMath.distance(from: sample.coordinate, to: gps.coordinate)
            <= gps.horizontalAccuracy + Self.disagreementAllowance
    }

    private func freshGPS(at time: Date) -> LocationSample? {
        guard let latestGPS, abs(time.timeIntervalSince(latestGPS.timestamp)) <= Self.gpsFreshness else { return nil }
        return latestGPS
    }
}
