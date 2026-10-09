import Foundation
import simd

/// The slab of space the user is about to walk through. All lengths in metres, in the
/// same coordinate space as the point cloud being tested against it.
/// Owner: Computer Vision (1.1 / task T11).
struct WalkingCorridor: Sendable {
    /// Where the user is — normally the camera position.
    let origin: SIMD3<Float>
    /// Direction of travel. Normalized on init.
    let forward: SIMD3<Float>
    /// Lateral axis, pointing to the user's right. Normalized on init.
    let right: SIMD3<Float>
    /// Full width, so the corridor extends `width / 2` either side of the forward ray.
    let width: Float
    /// How far ahead we care. Beyond this, obstacles are not yet actionable.
    let maxDistance: Float

    init(
        origin: SIMD3<Float>,
        forward: SIMD3<Float>,
        right: SIMD3<Float>,
        width: Float,
        maxDistance: Float
    ) {
        self.origin = origin
        self.forward = simd_length(forward) > 1e-6 ? simd_normalize(forward) : [0, 0, -1]
        self.right = simd_length(right) > 1e-6 ? simd_normalize(right) : [1, 0, 0]
        self.width = width
        self.maxDistance = maxDistance
    }

    /// A person's shoulders plus clearance (0.9 m), looking 4 m ahead, facing -Z as an
    /// ARKit camera does.
    static let `default` = WalkingCorridor(
        origin: .zero,
        forward: [0, 0, -1],
        right: [1, 0, 0],
        width: 0.9,
        maxDistance: 4
    )

    /// The same corridor with its axes re-orthogonalized to lie in the floor plane.
    ///
    /// Callers usually pass a camera transform's axes, which are tilted by however the
    /// phone is being held and drift out of orthogonality. Flattening first means
    /// "forward" means along the ground and "right" means level, which is what the
    /// width test assumes.
    ///
    /// Returns nil when `forward` is parallel to the floor normal — the user is pointing
    /// the camera straight down, and there is no meaningful direction of travel.
    func flattened(ontoFloorNormal normal: SIMD3<Float>) -> WalkingCorridor? {
        let n = simd_normalize(normal)
        let projected = forward - n * simd_dot(forward, n)
        guard simd_length(projected) > 1e-4 else { return nil }

        let f = simd_normalize(projected)
        // Derive `right` from the cross product rather than projecting the caller's own
        // right vector: that guarantees an orthonormal, right-handed basis even when the
        // input axes were skewed.
        let r = simd_cross(n, f)
        guard simd_length(r) > 1e-6 else { return nil }

        return WalkingCorridor(
            origin: origin,
            forward: f,
            right: simd_normalize(r),
            width: width,
            maxDistance: maxDistance
        )
    }
}
