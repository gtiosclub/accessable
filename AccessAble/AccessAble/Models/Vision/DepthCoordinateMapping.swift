import CoreGraphics

// FLAG (judgment call): the ticket's worked example (0.4, 0.3, 0.2, 0.4 → x≈102.4, y≈57.6 on a
// 256×192 depth map) scales the box directly with no y-flip, which only lines up if `boundingBox`
// is already top-left-origin — i.e. the app's convention (`Detection.boundingBox`), not raw
// Vision output (bottom-left-origin). We're taking that as the contract rather than flipping
// internally. If a caller ever passes a raw `VNObservation.boundingBox` here uncorrected, every
// detection will land vertically mirrored in the depth map — flip with
// `VisionCoordinates.flipped(_:)` first.
/// Maps a bounding box detected in the RGB camera image into the corresponding pixel region
/// of ARKit's LiDAR depth map, which is typically much lower resolution than the RGB frame
/// (e.g. 256×192 vs 1920×1440) but covers the same field of view.
///
/// `boundingBox` is expected in the app's normalized convention — origin top-left, y down,
/// 0...1 — the same convention as `Detection.boundingBox`. A raw Vision observation (origin
/// bottom-left) should be flipped first with `VisionCoordinates.flipped(_:)`.
///
/// Goes through RGB pixel space as an explicit intermediate step so the mapping stays correct
/// even if the RGB and depth buffers ever have different aspect ratios, then clips the result
/// to the depth map's bounds (a detection at the frame edge can otherwise round slightly outside
/// it). Returns `CGRect.null` if `rgbSize` is degenerate or the box doesn't overlap the depth map.
func mapRGBToDepth(boundingBox: CGRect, rgbSize: CGSize, depthSize: CGSize) -> CGRect {
    guard rgbSize.width > 0, rgbSize.height > 0 else { return .null }

    let rgbPixelRect = CGRect(
        x: boundingBox.minX * rgbSize.width,
        y: boundingBox.minY * rgbSize.height,
        width: boundingBox.width * rgbSize.width,
        height: boundingBox.height * rgbSize.height
    )

    let scaleX = depthSize.width / rgbSize.width
    let scaleY = depthSize.height / rgbSize.height

    let depthPixelRect = CGRect(
        x: rgbPixelRect.minX * scaleX,
        y: rgbPixelRect.minY * scaleY,
        width: rgbPixelRect.width * scaleX,
        height: rgbPixelRect.height * scaleY
    )

    return depthPixelRect.intersection(CGRect(origin: .zero, size: depthSize))
}
