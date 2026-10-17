import Foundation
import simd

// Turning a depth map into the point cloud that T10 and T11 consume (1.1).
//
// Kept free of ARKit: the input is a `DepthMap`, which the app fills from `sceneDepth` and a
// test builds directly. That is the seam that makes the geometry path verifiable on a Mac.

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

/// Unprojects a depth map into world-space points.
///
/// - Parameters:
///   - depth: The filtered depth map; unreliable pixels are skipped.
///   - intrinsics: Intrinsics already scaled to the depth map's size via `scaled(toWidth:height:)`.
///   - cameraTransform: Camera-space to world-space. ARKit's camera space is +X right,
///     +Y up, -Z forward, which is what the maths below assumes.
///   - sampleStride: Take every Nth pixel in each axis. 4 turns a 256x192 map into ~3000
///     points, plenty for plane fitting and clustering at a small per-frame cost.
func unprojectDepthMap(
    _ depth: DepthMap,
    intrinsics: CameraIntrinsics,
    cameraTransform: simd_float4x4,
    sampleStride: Int = 4
) -> [SIMD3<Float>] {
    guard sampleStride > 0, intrinsics.focalX != 0, intrinsics.focalY != 0 else { return [] }

    var points: [SIMD3<Float>] = []
    points.reserveCapacity((depth.width / sampleStride) * (depth.height / sampleStride))

    for row in stride(from: 0, to: depth.height, by: sampleStride) {
        for column in stride(from: 0, to: depth.width, by: sampleStride) {
            guard let z = depth[column, row] else { continue }
            let world = cameraTransform * SIMD4(cameraPoint(column: Float(column), row: Float(row), depth: z, intrinsics: intrinsics), 1)
            points.append(SIMD3(world.x, world.y, world.z))
        }
    }

    return points
}

/// Pinhole unprojection of a depth-map pixel into ARKit camera space. Image rows run
/// downwards and camera +Y runs up, hence the negated Y; camera -Z is forward, hence the
/// negated depth.
func cameraPoint(column: Float, row: Float, depth: Float, intrinsics: CameraIntrinsics) -> SIMD3<Float> {
    SIMD3(
        (column - intrinsics.principalX) / intrinsics.focalX * depth,
        -(row - intrinsics.principalY) / intrinsics.focalY * depth,
        -depth
    )
}
