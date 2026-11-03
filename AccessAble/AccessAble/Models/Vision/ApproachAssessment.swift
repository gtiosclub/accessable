import Foundation
import simd

// Which moving things are going to reach the user's path, and when (1.1 / task T34).
//
// The question is not "is this getting nearer" — a parked car gets nearer at walking pace.
// It is "will this come close to me, and how soon". For two things moving in straight lines
// that has a closed form: with `r` the object's position relative to the user and `v` its
// velocity relative to the user, they are nearest at t* = −dot(r, v) / dot(v, v), and the
// gap then is |r + v·t*|. Negative t* means the nearest approach has already happened and
// the object is leaving.
//
// Working in the relative frame is what makes the user's own walking cancel out, so the
// same test handles someone walking toward you, a cyclist crossing ahead, and a car you
// will pass two metres to the side.

/// When two things moving in straight lines will be nearest, and how near.
struct ClosestApproach: Equatable, Sendable {
    /// Seconds until the nearest point. Negative means it is already behind.
    let time: Float
    /// Distance in metres at that moment.
    let missDistance: Float
    /// Metres per second the gap is currently closing; negative while opening.
    let closingSpeed: Float
}

/// Where two things moving in straight lines come nearest.
///
/// - Parameters:
///   - relativePosition: The object's position minus the user's, in metres.
///   - relativeVelocity: The object's velocity minus the user's, in metres per second.
/// - Returns: nil when there is no relative motion at all, so there is no approach to
///   predict and the pair simply stays as it is.
func closestApproach(
    relativePosition: SIMD3<Float>,
    relativeVelocity: SIMD3<Float>
) -> ClosestApproach? {
    let speedSquared = simd_dot(relativeVelocity, relativeVelocity)
    guard speedSquared > 1e-6, speedSquared.isFinite else { return nil }

    let time = -simd_dot(relativePosition, relativeVelocity) / speedSquared
    let atApproach = relativePosition + relativeVelocity * time
    let missDistance = simd_length(atApproach)
    // Rate of change of separation: positive while the gap shrinks.
    let separation = simd_length(relativePosition)
    let closingSpeed = separation > 1e-6
        ? -simd_dot(relativePosition, relativeVelocity) / separation
        : 0
    guard time.isFinite, missDistance.isFinite, closingSpeed.isFinite else { return nil }

    return ClosestApproach(time: time, missDistance: missDistance, closingSpeed: closingSpeed)
}

/// One moving thing predicted to reach the user's path.
struct ApproachThreat: Identifiable, Equatable, Sendable {
    /// The track it was seen on, so a warning fires once per object rather than per frame.
    var id: UUID { trackID }
    let trackID: UUID
    let label: String
    /// Seconds until the nearest approach.
    let timeToApproach: Float
    /// How close it will come, in metres.
    let missDistance: Float
    /// Distance right now, in metres.
    let distance: Float
    /// Where it is now relative to the way the user is facing.
    let bearing: RelativeBearing
    /// The object's own speed over the ground, in metres per second.
    let speed: Float
}

/// Knobs for `approachThreats`.
struct ApproachTuning: Sendable {
    /// Labels worth warning about: people and anything on wheels. A moving chair is being
    /// carried by someone who can see; a moving car is not.
    var watchedLabels: Set<String> = [
        "person", "bicycle", "motorcycle", "car", "bus", "truck", "train",
    ]
    /// Least ground speed, in metres per second, that counts as moving rather than as
    /// something standing still being walked toward. A standing person sways and depth
    /// jitters, and anything slower than this belongs to T16, which already announces it.
    var minimumSpeed: Float = 0.7
    /// Only warn about an approach landing within this many seconds. Further ahead than
    /// this and the straight-line prediction is guesswork: people turn.
    var maximumTimeToApproach: Float = 6
    /// How much wider than the walking corridor still counts as reaching the user. Being
    /// missed by twenty centimetres is not being missed.
    var missMargin: Float = 0.6
    /// Ignore anything further away than this. Distances at that range are too uncertain,
    /// and the approach is too far off to be worth saying.
    var maximumDistance: Float = 15

    static let `default` = ApproachTuning()

    init() {}
}

/// The moving objects predicted to reach the user's path, most urgent first.
///
/// - Parameters:
///   - detections: This frame's detections, already tracked so `trackID` is set.
///   - motions: Fitted motion per track, from `MotionTracker`.
///   - userVelocity: The user's own velocity in world coordinates, metres per second.
///   - corridor: The walking corridor; supplies the user's position, facing and width.
/// - Returns: Threats sorted by `timeToApproach` ascending.
func approachThreats(
    detections: [Detection],
    motions: [UUID: TrackMotion],
    userVelocity: SIMD3<Float>,
    corridor: WalkingCorridor,
    tuning: ApproachTuning = .default
) -> [ApproachThreat] {
    let reach = corridor.width / 2 + tuning.missMargin

    var threats: [ApproachThreat] = []
    for detection in detections {
        guard let trackID = detection.trackID,
              tuning.watchedLabels.contains(detection.label.lowercased()),
              let motion = motions[trackID]
        else { continue }

        let speed = motion.groundSpeed()
        guard speed >= tuning.minimumSpeed else { continue }

        let relativePosition = motion.position - corridor.origin
        let distance = simd_length(relativePosition)
        guard distance.isFinite, distance <= tuning.maximumDistance else { continue }

        guard let approach = closestApproach(
            relativePosition: relativePosition,
            relativeVelocity: motion.velocity - userVelocity
        ) else { continue }

        // Already past its nearest point, or too far off to act on.
        guard approach.time >= 0, approach.time <= tuning.maximumTimeToApproach else { continue }
        guard approach.missDistance <= reach else { continue }

        threats.append(ApproachThreat(
            trackID: trackID,
            label: detection.label,
            timeToApproach: approach.time,
            missDistance: approach.missDistance,
            distance: distance,
            bearing: detection.bearing ?? corridor.bearing(to: motion.position),
            speed: speed
        ))
    }
    return threats.sorted {
        $0.timeToApproach != $1.timeToApproach
            ? $0.timeToApproach < $1.timeToApproach
            : $0.trackID.uuidString < $1.trackID.uuidString
    }
}
