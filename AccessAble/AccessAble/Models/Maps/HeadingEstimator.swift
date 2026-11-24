import Foundation

/// Which way the user is facing, as well as it can be told.
struct UserHeading: Equatable, Sendable {
    enum Source: String, Sendable { case ar, walkingDirection, compass }
    /// Degrees clockwise from true north, 0..<360.
    var degrees: Double
    var source: Source
    var timestamp: Date
}

/// Combines AR geo-tracking, the walking direction from location fixes and the compass into one heading, or none.
///
/// Deterministic: all time comes from sample timestamps and the time the caller asks about.
struct HeadingEstimator {
    private var location: LocationSample?
    private var compass: HeadingSample?
    private var arHeading: HeadingSample?

    // slower than a normal walk, faster than a phone drifting at a standstill, so the course follows real steps
    private static let minimumWalkingSpeed: Double = 0.7
    // a course rougher than this can point down the wrong street
    private static let maximumCourseError: Double = 45
    // close enough to tell one street from the next; worse means interference or a compass needing calibration
    private static let maximumCompassError: Double = 25
    /// Seconds a reading counts for; an older one may be from before the user turned.
    static let maximumSampleAge: TimeInterval = 3
    // as long as `LocationFusion` trusts a reading, so one dropped reading doesn't flip the source
    private static let maximumARAge = LocationFusion.arLifetime
    // Degrees. Walking, the camera's heading is used only this near the course: geo-tracking needs façades in view, so
    // the camera often points to the side of the way the user walks. A guess, unmeasured until the AR-6 walk.
    private static let maximumARCourseDisagreement: Double = 30

    mutating func update(with sample: LocationSample) {
        guard [sample.speed, sample.course, sample.courseAccuracy].allSatisfy({ $0?.isFinite ?? true }) else { return }
        if let location, sample.timestamp < location.timestamp { return }
        location = sample
    }

    mutating func update(with sample: HeadingSample) {
        guard sample.magneticHeading.isFinite, sample.accuracy.isFinite, sample.trueHeading?.isFinite ?? true else {
            return
        }
        switch sample.source {
        case .compass:
            if let compass, sample.timestamp < compass.timestamp { return }
            compass = sample
        case .ar:
            if let arHeading, sample.timestamp < arHeading.timestamp { return }
            arHeading = sample
        }
    }

    /// Degrees, of the latest compass reading, whether or not it is precise enough to use.
    var compassAccuracy: Double? { compass?.accuracy }

    /// nil means unknown: better no direction than a wrong one.
    func heading(at time: Date) -> UserHeading? {
        let ar = trustedARHeading(at: time)
        if let location, isFresh(location.timestamp, at: time), Self.isWalking(location) {
            // a phone swinging in a pocket, or a camera pointed at a building to the side for geo-tracking, faces
            // somewhere other than where the user walks
            guard let course = Self.walkingDirection(of: location) else { return nil }
            // the camera, matched to street imagery, sharpens a course it agrees with; it never overrules one
            if let ar, abs(RelativeBearing(degrees: ar.degrees - course).degrees) <= Self.maximumARCourseDisagreement {
                return ar
            }
            return UserHeading(degrees: course, source: .walkingDirection, timestamp: location.timestamp)
        }
        // standing still, the phone is all there is to go by, and the camera's heading is sharper than the compass;
        // with the speed unknown, as when AR has no fresh GPS fix to lend one, the user may be walking
        if let ar, let speed = location?.speed, speed < Self.minimumWalkingSpeed { return ar }
        guard let compass, compass.accuracy <= Self.maximumCompassError, isFresh(compass.timestamp, at: time) else {
            return nil
        }
        return UserHeading(degrees: compass.trueHeading ?? compass.magneticHeading, source: .compass,
                           timestamp: compass.timestamp)
    }

    /// Where the camera faces (AR-4), only from a reading the trip's own fusion passed on: its latest fix is AR's and
    /// fresh, and the heading is no newer than that fix. A heading and its fix share their update's timestamp, so a
    /// newer heading is from a reading the fusion turned down, such as one disagreeing with GPS.
    private func trustedARHeading(at time: Date) -> UserHeading? {
        guard let arHeading, let degrees = arHeading.trueHeading, arHeading.accuracy <= Self.maximumCompassError,
              time.timeIntervalSince(arHeading.timestamp) <= Self.maximumARAge,
              let location, location.source == .ar, isFresh(location.timestamp, at: time),
              arHeading.timestamp <= location.timestamp else { return nil }
        return UserHeading(degrees: degrees, source: .ar, timestamp: arHeading.timestamp)
    }

    /// The fix's direction of travel in degrees from true north, when it is moving at walking speed with a course
    /// precise enough to trust. Doesn't check how old the fix is.
    static func walkingDirection(of sample: LocationSample) -> Double? {
        guard isWalking(sample), let course = sample.course, course.isFinite,
              (sample.courseAccuracy ?? 0) <= maximumCourseError else { return nil }
        return course
    }

    private static func isWalking(_ sample: LocationSample) -> Bool {
        sample.speed.map { $0 >= minimumWalkingSpeed } ?? false
    }

    private func isFresh(_ timestamp: Date, at time: Date) -> Bool {
        time.timeIntervalSince(timestamp) <= Self.maximumSampleAge
    }
}
