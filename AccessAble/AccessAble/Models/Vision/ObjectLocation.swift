import CoreGraphics
import Foundation
import simd

// Placing a detected object in the world from the depth under its box (1.1 / task T7).

/// The world-space point at the centre of an object's box, at the object's estimated depth.
///
/// - Parameters:
///   - region: The object's box in normalized depth-map coordinates (`sensorRect(fromUpright:)`).
///   - intrinsics: Intrinsics scaled to `depth`'s size.
///   - cameraTransform: Camera-space to world-space, as for `unprojectDepthMap`.
/// - Returns: nil when there is too little reliable depth inside the box.
func worldPosition(
    ofRegion region: CGRect,
    in depth: DepthMap,
    intrinsics: CameraIntrinsics,
    cameraTransform: simd_float4x4,
    tuning: DistanceEstimationTuning = .default
) -> SIMD3<Float>? {
    guard let estimate = estimateDistance(region: region, in: depth, tuning: tuning) else { return nil }
    // Pixel indices address pixel centres, so normalized x maps to x * width - 0.5.
    let point = cameraPoint(
        column: Float(region.midX) * Float(depth.width) - 0.5,
        row: Float(region.midY) * Float(depth.height) - 0.5,
        depth: estimate.meters,
        intrinsics: intrinsics
    )
    let world = cameraTransform * SIMD4(point, 1)
    return SIMD3(world.x, world.y, world.z)
}

extension WalkingCorridor {
    /// Straight-line distance in metres from the corridor's origin to `point`.
    func distance(to point: SIMD3<Float>) -> Float {
        simd_length(point - origin)
    }

    /// Direction of `point` relative to the corridor's forward axis, measured in the plane
    /// spanned by `forward` and `right`: 0° ahead, negative left, positive right.
    func bearing(to point: SIMD3<Float>) -> RelativeBearing {
        let offset = point - origin
        let radians = atan2(simd_dot(offset, right), simd_dot(offset, forward))
        return RelativeBearing(degrees: Double(radians) * 180 / .pi)
    }
}
