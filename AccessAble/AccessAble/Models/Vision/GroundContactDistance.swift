import CoreGraphics
import ImageIO
import Foundation
import simd

// Placing an object without a depth sensor, from where it meets the floor (1.1 / task T33).
//
// A non-LiDAR iPhone still runs ARKit world tracking, so the camera pose carries true metric
// scale and `rawFeaturePoints` gives a sparse cloud the floor fitter (T10) can work with.
// Given a floor, the ray through the bottom of a detection box meets that plane where the
// object stands, and the intersection is a metric world position — no depth sensor and no
// depth model involved.
//
// Everything here works in normalized sensor coordinates, as T5 and T7 do, and takes the
// upright box with the frame's orientation so the rotation is undone exactly once, by
// `sensorPoint(fromUpright:)`. Angles are measured between rays rather than dividing by a
// focal length, which keeps it right in every interface orientation: there is no "vertical
// focal length" left to pick wrongly.

/// Knobs for `groundContactDistance`.
struct GroundContactTuning: Sendable {
    /// How far up from the box's bottom edge the contact line is taken, as a fraction of the
    /// box height. Boxes sit a few pixels low around feet and their shadows, so a small
    /// inset is steadier than the exact bottom row.
    var contactInset: CGFloat = 0.02
    /// Uncertainty in the camera's height above the floor, as a fraction of that height,
    /// when the floor was fitted this frame. For a ray meeting a plane `h` below the camera,
    /// distance scales with `h`, so a relative error in height is the same relative error in
    /// distance.
    var measuredFloorError: Float = 0.06
    /// The same where no floor has been fitted and `FloorMemory` is standing in a level plane
    /// at its assumed height. An adult holding a phone up to look ahead is 1.1–1.5 m above
    /// the floor, so assuming 1.3 m is good to roughly 0.2 m, or about 16%.
    var assumedFloorError: Float = 0.16
    /// Never claim better than this many metres however well the floor is known: the box's
    /// own bottom edge is only good to a few pixels.
    var minimumError: Float = 0.08
    /// Past this many metres the ray grazes the floor, and a pixel of box error moves the
    /// answer by metres. Beyond it no estimate is offered at all.
    var maxDistance: Float = 8

    static let `default` = GroundContactTuning()

    init() {}
}

/// A metric position for one object, worked out from its floor contact.
struct GroundContactEstimate: Equatable, Sendable {
    let position: SIMD3<Float>
    let meters: Float
    /// One-standard-deviation uncertainty in `meters`.
    let plusMinus: Float
}

/// Where an object standing on `floor` is, from the bottom of its detection box.
///
/// - Parameters:
///   - box: The detection's normalized box in the upright image (top-left origin).
///   - orientation: The frame's image orientation, as used for `sensorRect(fromUpright:)`.
///   - floor: This frame's floor estimate, measured or remembered.
///   - corridor: Supplies the camera position distance is measured from.
///   - intrinsics: Intrinsics for the captured image, unscaled.
///   - cameraTransform: `ARFrame.camera.transform`.
/// - Returns: nil when the contact ray misses the floor ahead of the camera — a box whose
///   bottom sits above the horizon, which is anything not standing on the ground — or when
///   the intersection lands beyond `maxDistance`.
func groundContactDistance(
    box: CGRect,
    orientation: CGImagePropertyOrientation,
    floor: FloorEstimate,
    corridor: WalkingCorridor,
    intrinsics: CameraIntrinsics,
    cameraTransform: simd_float4x4,
    tuning: GroundContactTuning = .default
) -> GroundContactEstimate? {
    guard box.height > 0 else { return nil }
    let contactY = box.maxY - box.height * tuning.contactInset
    let contact = orientation.sensorPoint(fromUpright: CGPoint(x: box.midX, y: contactY))
    guard let position = floorIntersection(
        sensorPoint: contact, intrinsics: intrinsics, cameraTransform: cameraTransform, plane: floor.plane
    ) else { return nil }

    let meters = corridor.distance(to: position)
    guard meters.isFinite, meters > 0, meters <= tuning.maxDistance else { return nil }

    let relative = floor.isMeasured ? tuning.measuredFloorError : tuning.assumedFloorError
    return GroundContactEstimate(
        position: position,
        meters: meters,
        plusMinus: max(meters * relative, tuning.minimumError)
    )
}

/// Where the ray through a normalized sensor point meets `plane`, in world coordinates.
func floorIntersection(
    sensorPoint point: CGPoint,
    intrinsics: CameraIntrinsics,
    cameraTransform: simd_float4x4,
    plane: Plane3D
) -> SIMD3<Float>? {
    guard let direction = worldRayDirection(
        sensorPoint: point, intrinsics: intrinsics, cameraTransform: cameraTransform
    ) else { return nil }
    let origin = cameraPosition(of: cameraTransform)
    guard isFiniteVector(origin) else { return nil }

    let denominator = simd_dot(direction, plane.normal)
    // Near-parallel to the floor: the intersection runs off to the horizon, where the
    // distance it implies means nothing.
    guard abs(denominator) > 1e-4 else { return nil }
    let along = simd_dot(plane.point - origin, plane.normal) / denominator
    guard along.isFinite, along > 0 else { return nil }
    return origin + direction * along
}

/// The world point `meters` along the ray through a normalized sensor point. Used to place
/// an object whose distance came from its apparent size, where there is no floor contact.
func worldPoint(
    sensorPoint point: CGPoint,
    atDistance meters: Float,
    intrinsics: CameraIntrinsics,
    cameraTransform: simd_float4x4
) -> SIMD3<Float>? {
    guard meters.isFinite, meters > 0, let direction = worldRayDirection(
        sensorPoint: point, intrinsics: intrinsics, cameraTransform: cameraTransform
    ) else { return nil }
    return cameraPosition(of: cameraTransform) + direction * meters
}

/// Unit direction, in camera space, of the ray through a normalized sensor point.
func cameraRayDirection(sensorPoint point: CGPoint, intrinsics: CameraIntrinsics) -> SIMD3<Float>? {
    // Pixel indices address pixel centres, as in `unprojectDepthMap`.
    let column = Float(point.x) * Float(intrinsics.imageWidth) - 0.5
    let row = Float(point.y) * Float(intrinsics.imageHeight) - 0.5
    // Depth 1 turns the unprojection into a direction.
    let local = cameraPoint(column: column, row: row, depth: 1, intrinsics: intrinsics)
    guard isFiniteVector(local), simd_length(local) > 1e-6 else { return nil }
    return simd_normalize(local)
}

/// Unit direction, in world space, of the ray through a normalized sensor point.
func worldRayDirection(
    sensorPoint point: CGPoint,
    intrinsics: CameraIntrinsics,
    cameraTransform: simd_float4x4
) -> SIMD3<Float>? {
    guard let local = cameraRayDirection(sensorPoint: point, intrinsics: intrinsics) else { return nil }
    // A direction, so w = 0: the camera's translation must not be added in.
    let rotated = cameraTransform * SIMD4(local, 0)
    let direction = SIMD3(rotated.x, rotated.y, rotated.z)
    guard isFiniteVector(direction), simd_length(direction) > 1e-6 else { return nil }
    return simd_normalize(direction)
}

private func cameraPosition(of transform: simd_float4x4) -> SIMD3<Float> {
    SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
}

private func isFiniteVector(_ vector: SIMD3<Float>) -> Bool {
    vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
}
