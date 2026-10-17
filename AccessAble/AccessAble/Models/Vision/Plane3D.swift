import Foundation
import simd

/// An infinite plane in the point cloud's 3D coordinate space. All lengths in metres.
/// Owner: Computer Vision (1.1 / task T10).
struct Plane3D: Equatable, Sendable {
    /// Unit length. Oriented into the same hemisphere as the caller's up hint, so a
    /// positive signed distance always means "above the floor".
    let normal: SIMD3<Float>
    /// Any point lying on the plane. `detectFloorPlane` returns the centroid of the
    /// points that supported the fit.
    let point: SIMD3<Float>

    /// `normal` is normalized here, so callers may pass an unnormalized direction.
    init(normal: SIMD3<Float>, point: SIMD3<Float>) {
        self.normal = simd_normalize(normal)
        self.point = point
    }

    /// A perfectly level plane `height` metres along `up`. For fixtures and tests.
    static func horizontal(atHeight height: Float, up: SIMD3<Float> = [0, 1, 0]) -> Plane3D {
        let n = simd_normalize(up)
        return Plane3D(normal: n, point: n * height)
    }

    /// `point` dropped perpendicularly onto the plane.
    func project(_ point: SIMD3<Float>) -> SIMD3<Float> {
        point - normal * distanceFromPlane(point: point, plane: self)
    }

    /// Height of the plane along `up`, measured through the origin. Used to tell a floor
    /// from a tabletop when both are equally well supported.
    func elevation(along up: SIMD3<Float>) -> Float {
        simd_dot(point, simd_normalize(up))
    }
}

/// Signed perpendicular distance from `point` to `plane`, in metres: positive above the
/// plane, negative below it, ~0 on it. "Above" follows `plane.normal`.
func distanceFromPlane(point: SIMD3<Float>, plane: Plane3D) -> Float {
    simd_dot(point - plane.point, plane.normal)
}
