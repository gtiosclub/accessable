import CoreGraphics
import ImageIO
import Foundation
import simd

// Distance from how large something of known size appears (1.1 / task T33).
//
// Pinhole geometry: an object `h` metres tall subtending an angle θ at the camera stands
// `h / (2 tan(θ/2))` away. θ is measured between the rays through the top and bottom of the
// detection box, so no focal axis has to be chosen — see `GroundContactDistance.swift`.
//
// This is a cross-check, not a primary source. Real objects vary: calling every adult 1.7 m
// tall is already wrong by about 15% before the detector's box error is counted. So the
// prior is a range and the answer is a range, and the width of that range is the honest
// uncertainty rather than something to hide.

/// A plausible real-world height range for one label, in metres.
struct ObjectSizePrior: Equatable, Sendable {
    let label: String
    let heightRange: ClosedRange<Float>

    init(label: String, heightRange: ClosedRange<Float>) {
        self.label = label
        self.heightRange = heightRange
    }
}

/// Height priors for the labels worth estimating from, keyed by `Detection.label`.
///
/// Only things met at ground level while walking, and only where the range is tight enough
/// to carry information. A dog's 0.25–0.8 m spread is kept because a loose answer with
/// honest error bars still beats no answer at all, but anything looser is left out: a prior
/// wider than the room is not information. Labels match the detector's own spelling.
enum ObjectSizePriors {
    static let byLabel: [String: ObjectSizePrior] = [
        "person": ObjectSizePrior(label: "person", heightRange: 1.45 ... 1.95),
        "bicycle": ObjectSizePrior(label: "bicycle", heightRange: 0.95 ... 1.15),
        "motorcycle": ObjectSizePrior(label: "motorcycle", heightRange: 1.00 ... 1.30),
        "car": ObjectSizePrior(label: "car", heightRange: 1.35 ... 1.85),
        "bus": ObjectSizePrior(label: "bus", heightRange: 2.80 ... 3.40),
        "truck": ObjectSizePrior(label: "truck", heightRange: 2.40 ... 4.00),
        "chair": ObjectSizePrior(label: "chair", heightRange: 0.75 ... 1.15),
        "bench": ObjectSizePrior(label: "bench", heightRange: 0.75 ... 0.95),
        "couch": ObjectSizePrior(label: "couch", heightRange: 0.70 ... 0.95),
        "dining table": ObjectSizePrior(label: "dining table", heightRange: 0.70 ... 0.80),
        "refrigerator": ObjectSizePrior(label: "refrigerator", heightRange: 1.60 ... 1.90),
        "fire hydrant": ObjectSizePrior(label: "fire hydrant", heightRange: 0.60 ... 0.90),
        "stop sign": ObjectSizePrior(label: "stop sign", heightRange: 0.60 ... 0.90),
        "parking meter": ObjectSizePrior(label: "parking meter", heightRange: 1.10 ... 1.50),
        "door": ObjectSizePrior(label: "door", heightRange: 1.95 ... 2.10),
        "dog": ObjectSizePrior(label: "dog", heightRange: 0.25 ... 0.80),
    ]

    static func prior(for label: String) -> ObjectSizePrior? {
        byLabel[label.lowercased()]
    }
}

/// The angle in radians between the rays through two normalized sensor points.
func subtendedAngle(from a: CGPoint, to b: CGPoint, intrinsics: CameraIntrinsics) -> Float? {
    guard let first = cameraRayDirection(sensorPoint: a, intrinsics: intrinsics),
          let second = cameraRayDirection(sensorPoint: b, intrinsics: intrinsics)
    else { return nil }
    let angle = acos(min(max(simd_dot(first, second), -1), 1))
    return angle.isFinite ? angle : nil
}

/// The distances consistent with `box` being an object of `prior`'s height.
///
/// - Parameters:
///   - box: The detection's normalized box in the upright image (top-left origin).
///   - orientation: The frame's image orientation.
///   - intrinsics: Intrinsics for the captured image, unscaled.
///   - edgeTolerance: How close to the frame edge counts as touching it.
/// - Returns: nil when the box touches the frame edge, because a clipped box has lost part
///   of the object and its height no longer says anything about the object's size. This is
///   the commonest way the estimate goes badly wrong — a person half out of frame looks
///   small, and so looks far away.
func distanceRange(
    box: CGRect,
    orientation: CGImagePropertyOrientation,
    prior: ObjectSizePrior,
    intrinsics: CameraIntrinsics,
    edgeTolerance: CGFloat = 0.01
) -> ClosedRange<Float>? {
    guard box.height > 0, box.width > 0,
          box.minX > edgeTolerance, box.maxX < 1 - edgeTolerance,
          box.minY > edgeTolerance, box.maxY < 1 - edgeTolerance
    else { return nil }

    let top = orientation.sensorPoint(fromUpright: CGPoint(x: box.midX, y: box.minY))
    let bottom = orientation.sensorPoint(fromUpright: CGPoint(x: box.midX, y: box.maxY))
    guard let angle = subtendedAngle(from: top, to: bottom, intrinsics: intrinsics), angle > 1e-5
    else { return nil }

    let scale = 2 * tan(angle / 2)
    guard scale > 1e-6 else { return nil }
    let near = prior.heightRange.lowerBound / scale
    let far = prior.heightRange.upperBound / scale
    guard near.isFinite, far.isFinite, near > 0, far >= near else { return nil }
    return near ... far
}
