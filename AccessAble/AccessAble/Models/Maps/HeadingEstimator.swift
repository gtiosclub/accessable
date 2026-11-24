import Foundation

/// Which way the user is facing, as well as it can be told.
struct UserHeading: Equatable, Sendable {
    enum Source: String, Sendable { case walkingDirection, compass }
    /// Degrees clockwise from true north, 0..<360.
    var degrees: Double
    var source: Source
    var timestamp: Date
}

/// Combines the walking direction from location fixes with the compass into one heading, or none.
///
/// Deterministic: all time comes from sample timestamps and the time the caller asks about.
struct HeadingEstimator {
    private var location: LocationSample?
    private var compass: HeadingSample?

    // slower than a normal walk, faster than a phone drifting at a standstill, so the course follows real steps
    private static let minimumWalkingSpeed: Double = 0.7
    // a course rougher than this can point down the wrong street
    private static let maximumCourseError: Double = 45
    // close enough to tell one street from the next; worse means interference or a compass needing calibration
    private static let maximumCompassError: Double = 25
    /// Seconds a reading counts for; an older one may be from before the user turned.
    static let maximumSampleAge: TimeInterval = 3

    mutating func update(with sample: LocationSample) {
        guard [sample.speed, sample.course, sample.courseAccuracy].allSatisfy({ $0?.isFinite ?? true }) else { return }
        if let location, sample.timestamp < location.timestamp { return }
        location = sample
    }

    mutating func update(with sample: HeadingSample) {
        guard sample.magneticHeading.isFinite, sample.accuracy.isFinite, sample.trueHeading?.isFinite ?? true else {
            return
        }
        if let compass, sample.timestamp < compass.timestamp { return }
        compass = sample
    }

    /// Degrees, of the latest compass reading, whether or not it is precise enough to use.
    var compassAccuracy: Double? { compass?.accuracy }

    /// nil means unknown: better no direction than a wrong one.
    func heading(at time: Date) -> UserHeading? {
        if let location, isFresh(location.timestamp, at: time), Self.isWalking(location) {
            // a phone swinging in a pocket gives a compass reading that isn't where the user faces
            guard let course = Self.walkingDirection(of: location) else { return nil }
            return UserHeading(degrees: course, source: .walkingDirection, timestamp: location.timestamp)
        }
        guard let compass, compass.accuracy <= Self.maximumCompassError, isFresh(compass.timestamp, at: time) else {
            return nil
        }
        return UserHeading(degrees: compass.trueHeading ?? compass.magneticHeading, source: .compass,
                           timestamp: compass.timestamp)
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
