import Foundation
import simd

// How fast a tracked object is moving through the world (1.1 / task T34).
//
// ARKit's world frame is fixed while tracking runs, so differentiating a track's
// `worldPosition` gives the object's own motion with the user's walking already taken out.
// That distinction is the whole point: a parked car gets nearer at walking pace and is not
// approaching anybody, while a cyclist crossing ahead is barely getting nearer and is.
//
// Velocity comes from a least-squares line fit over a short history rather than from the
// difference between two frames. Positions carry a few centimetres of depth noise, and over
// a 0.1 s gap that alone is ±0.4 m/s — enough to invent an approaching vehicle out of a
// stationary one. A fit over several samples averages it down.

/// One position reading for a track, in ARKit world coordinates.
struct MotionSample: Equatable, Sendable {
    /// Frame capture time in seconds, e.g. `ARFrame.timestamp`.
    let time: TimeInterval
    let position: SIMD3<Float>
}

/// What the history says about where something is and where it is going.
struct TrackMotion: Equatable, Sendable {
    /// The most recent position, in world coordinates.
    let position: SIMD3<Float>
    /// Metres per second in world coordinates, from the fit.
    let velocity: SIMD3<Float>
    /// How many samples the fit used.
    let sampleCount: Int
    /// Seconds between the oldest and newest sample used.
    let timeSpan: TimeInterval

    /// Speed over the ground, in metres per second. Vertical motion is dropped: a detection
    /// box breathing up and down a few centimetres is noise, not travel.
    func groundSpeed(up: SIMD3<Float> = [0, 1, 0]) -> Float {
        let levelled = velocity - simd_normalize(up) * simd_dot(velocity, simd_normalize(up))
        return simd_length(levelled)
    }
}

/// Position history for one thing, with a velocity fitted to it.
struct MotionHistory: Sendable {
    /// Samples older than this many seconds are dropped. Long enough to average out depth
    /// noise, short enough that a change of direction is not smeared across it.
    var window: TimeInterval = 0.6
    /// A fit needs at least this many samples.
    var minimumSamples: Int = 3
    /// A fit needs at least this much time between first and last sample, or the velocity is
    /// a very small displacement divided by a very small interval.
    var minimumTimeSpan: TimeInterval = 0.2

    private var samples: [MotionSample] = []

    init() {}

    /// Adds a reading and forgets anything that has fallen out of the window.
    ///
    /// Out-of-order and duplicate timestamps are dropped: frames arrive in order, and a
    /// repeated timestamp would be a zero-length interval in the fit.
    mutating func record(position: SIMD3<Float>, at time: TimeInterval) {
        guard time.isFinite, position.x.isFinite, position.y.isFinite, position.z.isFinite else { return }
        if let last = samples.last, time <= last.time { return }
        samples.append(MotionSample(time: time, position: position))
        let cutoff = time - window
        samples.removeAll { $0.time < cutoff }
    }

    var lastSeen: TimeInterval? { samples.last?.time }

    /// The fitted motion, or nil while there is too little history to believe one.
    var motion: TrackMotion? {
        guard samples.count >= minimumSamples, let first = samples.first, let last = samples.last else { return nil }
        let span = last.time - first.time
        guard span >= minimumTimeSpan else { return nil }

        // Least squares on each axis: slope = Σ(t−t̄)(p−p̄) / Σ(t−t̄)².
        let meanTime = samples.reduce(0.0) { $0 + $1.time } / Double(samples.count)
        var meanPosition = SIMD3<Float>(repeating: 0)
        for sample in samples { meanPosition += sample.position }
        meanPosition /= Float(samples.count)

        var numerator = SIMD3<Float>(repeating: 0)
        var denominator: Float = 0
        for sample in samples {
            let dt = Float(sample.time - meanTime)
            numerator += (sample.position - meanPosition) * dt
            denominator += dt * dt
        }
        guard denominator > 1e-6 else { return nil }
        let velocity = numerator / denominator
        guard velocity.x.isFinite, velocity.y.isFinite, velocity.z.isFinite else { return nil }

        return TrackMotion(
            position: last.position, velocity: velocity,
            sampleCount: samples.count, timeSpan: span
        )
    }
}

/// Keeps a `MotionHistory` per track, fed from each frame's detections.
///
/// Keyed on `Detection.trackID`, so it inherits T15's identities — and T15's weakness: box
/// overlap alone splits a track under fast lateral motion, which is exactly when something
/// is crossing the path. A split track starts its history again and stays silent until the
/// window refills.
struct MotionTracker: Sendable {
    /// A track not updated for this long is forgotten.
    var maximumAge: TimeInterval = 0.6
    var history = MotionHistory()

    private var histories: [UUID: MotionHistory] = [:]

    init() {}

    /// Records this frame's positions and returns the motion of every track that has enough
    /// history for one.
    ///
    /// Detections without a `trackID` or a `worldPosition` are skipped: there is nothing to
    /// key on, or nothing to measure.
    mutating func update(_ detections: [Detection], at time: TimeInterval) -> [UUID: TrackMotion] {
        for detection in detections {
            guard let trackID = detection.trackID, let position = detection.worldPosition else { continue }
            var entry = histories[trackID] ?? history
            entry.record(position: position, at: time)
            histories[trackID] = entry
        }
        histories = histories.filter { time - ($0.value.lastSeen ?? -.infinity) <= maximumAge }
        return histories.compactMapValues(\.motion)
    }

    /// Forget everything, e.g. when tracking restarts and world coordinates change meaning.
    mutating func reset() {
        histories.removeAll()
    }
}
