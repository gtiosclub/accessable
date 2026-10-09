import Foundation
import simd

// Turning a depth map into the point cloud that T10 and T11 consume (1.1).
//
// Kept free of ARKit and CoreVideo: the depth map is read through a closure, so this can
// be driven from an ARKit `sceneDepth` buffer in the app and from a synthetic buffer in a
// test. That is the seam that makes the whole geometry path verifiable on a Mac.

/// Pinhole camera intrinsics, in pixels, for an image of `imageWidth` x `imageHeight`.
struct CameraIntrinsics: Sendable {
    let focalX: Float
    let focalY: Float
    /// Principal point, in pixels from the image's top-left corner.
    let principalX: Float
    let principalY: Float
    let imageWidth: Int
    let imageHeight: Int

    init(focalX: Float, focalY: Float, principalX: Float, principalY: Float, imageWidth: Int, imageHeight: Int) {
        self.focalX = focalX
        self.focalY = focalY
        self.principalX = principalX
        self.principalY = principalY
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    /// The same optics expressed for a different raster size.
    ///
    /// Needed because ARKit reports intrinsics for the captured image (around 1920x1440)
    /// while the LiDAR depth map is far smaller (around 256x192). Using the unscaled
    /// intrinsics against the depth map is the single easiest way to get a point cloud
    /// that looks plausible and is quietly wrong.
    func scaled(toWidth width: Int, height: Int) -> CameraIntrinsics {
        let sx = Float(width) / Float(imageWidth)
        let sy = Float(height) / Float(imageHeight)
        return CameraIntrinsics(
            focalX: focalX * sx,
            focalY: focalY * sy,
            principalX: principalX * sx,
            principalY: principalY * sy,
            imageWidth: width,
            imageHeight: height
        )
    }
}

/// Knobs for `unprojectDepthMap`.
struct DepthUnprojectionTuning: Sendable {
    /// Take every Nth pixel in each axis. 4 turns a 256x192 map into ~3000 points, which
    /// is plenty for plane fitting and clustering and keeps the per-frame cost small.
    var sampleStride: Int = 4
    /// Depth values outside this range are discarded, in metres. Below the near limit is
    /// usually the user's own hand or body; beyond the far limit LiDAR returns get too
    /// sparse and noisy to cluster.
    var depthRange: ClosedRange<Float> = 0.2 ... 6.0

    static let `default` = DepthUnprojectionTuning()

    init() {}
}

/// Unprojects a depth map into world-space points.
///
/// - Parameters:
///   - width: Depth map width in pixels.
///   - height: Depth map height in pixels.
///   - intrinsics: Intrinsics already scaled to `width` x `height` via `scaled(toWidth:height:)`.
///   - cameraTransform: Camera-space to world-space. ARKit's camera space is +X right,
///     +Y up, -Z forward, which is what the maths below assumes.
///   - depthAt: Depth in metres along the optical axis at a depth-map pixel, `(column, row)`
///     from the top-left. Return a non-finite value for a pixel with no return.
///   - isConfident: Optional per-pixel filter, for ARKit's confidence map.
func unprojectDepthMap(
    width: Int,
    height: Int,
    intrinsics: CameraIntrinsics,
    cameraTransform: simd_float4x4,
    tuning: DepthUnprojectionTuning = .default,
    depthAt: (Int, Int) -> Float,
    isConfident: ((Int, Int) -> Bool)? = nil
) -> [SIMD3<Float>] {
    guard width > 0, height > 0, tuning.sampleStride > 0 else { return [] }
    guard intrinsics.focalX != 0, intrinsics.focalY != 0 else { return [] }

    var points: [SIMD3<Float>] = []
    points.reserveCapacity((width / tuning.sampleStride) * (height / tuning.sampleStride))

    for row in stride(from: 0, to: height, by: tuning.sampleStride) {
        for column in stride(from: 0, to: width, by: tuning.sampleStride) {
            let depth = depthAt(column, row)
            guard depth.isFinite, tuning.depthRange.contains(depth) else { continue }
            if let isConfident, !isConfident(column, row) { continue }

            // Pinhole unprojection. Image rows run downwards and camera +Y runs up, hence
            // the negated Y; camera -Z is forward, hence the negated depth.
            let cameraPoint = SIMD4<Float>(
                (Float(column) - intrinsics.principalX) / intrinsics.focalX * depth,
                -(Float(row) - intrinsics.principalY) / intrinsics.focalY * depth,
                -depth,
                1
            )
            let world = cameraTransform * cameraPoint
            points.append(SIMD3(world.x, world.y, world.z))
        }
    }

    return points
}
