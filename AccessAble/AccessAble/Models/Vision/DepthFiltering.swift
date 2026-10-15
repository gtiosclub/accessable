import ARKit
import CoreVideo
import Foundation

// FLAG (judgment call): the ticket didn't pin down "useful operating range" or the confidence
// bar, so these two defaults are our own call, not a spec'd number — 0.1–5.0m and medium+
// confidence are reasonable starting points for walking-speed obstacle detection, but the CV
// subteam should tune them against real LiDAR captures (both are overridable per call via
// `validRange`/`minimumConfidence`, so this is a default, not a hard limit).

/// Depth values outside this range (metres) aren't useful for walking-speed obstacle detection:
/// anything at/below zero is sensor noise, and LiDAR gets too noisy past a few metres.
private let defaultValidDepthRange: ClosedRange<Float> = 0.1...5.0

/// ARKit's confidence levels are `low = 0`, `medium = 1`, `high = 2`. Require at least medium.
private let defaultMinimumConfidence: UInt8 = 1

/// Reads the depth at `(x, y)` and returns `nil` if the measurement is unreliable: non-finite,
/// non-positive, outside `validRange`, or (when a confidence map is supplied) below
/// `minimumConfidence`. `confidenceMap`, when present, is assumed to have the same pixel
/// dimensions as `depthMap` — true for `ARDepthData.depthMap`/`confidenceMap` pairs.
func reliableDepth(
    x: Int,
    y: Int,
    depthMap: CVPixelBuffer,
    confidenceMap: CVPixelBuffer?,
    validRange: ClosedRange<Float> = defaultValidDepthRange,
    minimumConfidence: UInt8 = defaultMinimumConfidence
) -> Float? {
    guard let depth = readFloat32(x: x, y: y, from: depthMap) else { return nil }
    guard depth.isFinite, depth > 0, validRange.contains(depth) else { return nil }

    if let confidenceMap {
        guard let confidence = readUInt8(x: x, y: y, from: confidenceMap),
              confidence >= minimumConfidence else { return nil }
    }

    return depth
}

/// Convenience overload for ARKit's `ARDepthData`.
func reliableDepth(x: Int, y: Int, depthData: ARDepthData) -> Float? {
    reliableDepth(x: x, y: y, depthMap: depthData.depthMap, confidenceMap: depthData.confidenceMap)
}

/// Filters an entire depth map at once. The outer array is rows (height), the inner array is
/// columns (width); each entry is `nil` wherever that pixel's depth is unreliable.
func reliableDepthMap(depthMap: CVPixelBuffer, confidenceMap: CVPixelBuffer?) -> [[Float?]] {
    let width = CVPixelBufferGetWidth(depthMap)
    let height = CVPixelBufferGetHeight(depthMap)
    return (0..<height).map { y in
        (0..<width).map { x in
            reliableDepth(x: x, y: y, depthMap: depthMap, confidenceMap: confidenceMap)
        }
    }
}

private func readFloat32(x: Int, y: Int, from pixelBuffer: CVPixelBuffer) -> Float? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard x >= 0, x < width, y >= 0, y < height,
          let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
    return row[x]
}

private func readUInt8(x: Int, y: Int, from pixelBuffer: CVPixelBuffer) -> UInt8? {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard x >= 0, x < width, y >= 0, y < height,
          let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
    return row[x]
}
