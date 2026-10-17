import Foundation
import simd

// Keeping a floor when the camera cannot see one (1.1 / T10, T11).
//
// T11 measures every obstacle against the floor plane, and T10 can only fit a floor that is
// in view. Walk up to a wall and the floor leaves the bottom of the frame about 2 m out —
// exactly where the wall needs announcing — and a pipeline that requires a fresh fit every
// frame goes silent. The world is gravity-aligned and the phone stays at roughly the same
// height while walking, so the floor is where it was: a horizontal plane the remembered
// camera height below the camera.

/// The floor plane to use this frame, and how much it is worth.
struct FloorEstimate: Equatable, Sendable {
    let plane: Plane3D
    /// True when the plane was fitted to this frame's points; false when it is remembered or
    /// assumed. Obstacles can be measured against either; kerb detection needs a measured one.
    let isMeasured: Bool
    /// Signed height of the camera above `plane`, in metres.
    let cameraHeight: Float
}

/// Carries the floor across frames. Feed it every frame's fit (or nil); it always answers.
struct FloorMemory: Sendable {
    /// Camera height assumed before any floor has ever been fitted. Chest height for an
    /// adult holding the phone up to look ahead.
    var defaultCameraHeight: Float = 1.3
    /// A fit putting the camera outside this range is not the floor — a tabletop, a
    /// landing seen from a staircase — and is ignored.
    var plausibleCameraHeights: ClosedRange<Float> = 0.4 ... 2.5
    /// A plane tilted further than this from `up` is not a floor whatever its support.
    var maxTiltDegrees: Float = 30
    /// A fit that moves the camera height by more than this from the remembered height is
    /// suspect: a tabletop, a hand over the lens, a landing. Lifting the phone from waist
    /// to chest takes many frames, each a small change, and passes.
    var maximumHeightJump: Float = 0.35
    /// A suspect height is accepted once this many consecutive fits agree on it, so a
    /// genuine change (sitting down, a different user) gets through in under a second.
    var jumpConfirmationFrames = 5
    /// How closely consecutive suspect fits must agree to count as the same new height.
    var jumpAgreement: Float = 0.15
    /// How long the last fitted plane is reused as it is. After this it is replaced by a
    /// level plane that follows the camera, so a stale tilt cannot be extrapolated.
    var holdFittedPlane: TimeInterval = 1.5

    private var lastPlane: Plane3D?
    private var lastFitTime: TimeInterval = -.infinity
    private var lastCameraHeight: Float?
    private var pendingHeight: Float?
    private var pendingFrames = 0

    init() {}

    /// Height the camera was last measured above the floor, if ever.
    var rememberedCameraHeight: Float? { lastCameraHeight }

    /// Records this frame's fit, if any, and returns the floor to use.
    ///
    /// - Parameters:
    ///   - fit: T10's result for this frame's point cloud, or nil when it found none.
    ///   - cameraPosition: Where the camera is, in the cloud's coordinate space.
    ///   - up: World up. ARKit's gravity-aligned world gives `[0, 1, 0]`.
    ///   - time: The frame's capture time in seconds.
    mutating func update(
        fit: FloorPlaneFit?,
        cameraPosition: SIMD3<Float>,
        up: SIMD3<Float> = [0, 1, 0],
        at time: TimeInterval
    ) -> FloorEstimate {
        if let fit, let height = acceptableHeight(of: fit.plane, cameraPosition: cameraPosition, up: up, at: time) {
            lastPlane = fit.plane
            lastFitTime = time
            lastCameraHeight = height
            return FloorEstimate(plane: fit.plane, isMeasured: true, cameraHeight: height)
        }

        if let lastPlane, time - lastFitTime <= holdFittedPlane {
            return FloorEstimate(
                plane: lastPlane,
                isMeasured: false,
                cameraHeight: distanceFromPlane(point: cameraPosition, plane: lastPlane)
            )
        }

        let height = lastCameraHeight ?? defaultCameraHeight
        let n = simd_normalize(up)
        return FloorEstimate(
            plane: Plane3D(normal: n, point: cameraPosition - n * height),
            isMeasured: false,
            cameraHeight: height
        )
    }

    /// Forget everything, e.g. when tracking restarts and world coordinates change.
    mutating func reset() {
        lastPlane = nil
        lastFitTime = -.infinity
        lastCameraHeight = nil
        pendingHeight = nil
        pendingFrames = 0
    }

    private mutating func acceptableHeight(
        of plane: Plane3D, cameraPosition: SIMD3<Float>, up: SIMD3<Float>, at time: TimeInterval
    ) -> Float? {
        guard simd_dot(plane.normal, simd_normalize(up)) >= cos(maxTiltDegrees * .pi / 180) else { return nil }
        let height = distanceFromPlane(point: cameraPosition, plane: plane)
        guard height.isFinite, plausibleCameraHeights.contains(height) else { return nil }
        if let previous = lastCameraHeight, abs(height - previous) > maximumHeightJump {
            if let pending = pendingHeight, abs(height - pending) <= jumpAgreement {
                pendingFrames += 1
            } else {
                pendingHeight = height
                pendingFrames = 1
            }
            guard pendingFrames >= jumpConfirmationFrames else { return nil }
        }
        pendingHeight = nil
        pendingFrames = 0
        return height
    }
}
