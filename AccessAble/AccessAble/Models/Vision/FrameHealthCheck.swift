import Foundation
import simd

// Owner: Computer Vision (1.4 / task T1).
//
// The T1 acceptance list ("session starts, frames arrive, capturedImage is there,
// timestamps update, the camera transform changes as the phone moves") as plain math, so
// it can be unit-tested without a camera. `ARSessionManager` feeds one of these from the
// live session; tests feed it made-up frames.
//
// Deliberately ARKit-free (only `simd`), which is why it lives in Models/Vision and the
// SwiftPM test target can compile it on a Mac.

/// A snapshot of how the shared camera session is doing.
struct FrameHealthReport: Equatable, Sendable {
    var framesReceived: Int = 0
    /// Frames whose captured image was empty (zero width or height).
    var framesMissingImage: Int = 0
    /// False as soon as one frame arrives with a timestamp at or before the previous one.
    var timestampsAlwaysIncrease: Bool = true
    var firstTimestamp: TimeInterval?
    var lastTimestamp: TimeInterval?
    /// Furthest the camera has moved from where it was on the first frame, in metres.
    var maxTravelMeters: Float = 0
    /// Largest rotation away from the first frame's orientation, in degrees.
    var maxRotationDegrees: Float = 0

    /// Frames per second over the whole run, or nil until there are two frames.
    var averageFPS: Double? {
        guard framesReceived > 1,
              let first = firstTimestamp,
              let last = lastTimestamp,
              last > first
        else { return nil }
        return Double(framesReceived - 1) / (last - first)
    }

    /// True once the camera has moved or turned enough that the transform is clearly live,
    /// not stuck at identity. 5 cm or 5 degrees: well above sensor jitter, well below what
    /// any real hand movement produces.
    var cameraHasMoved: Bool {
        maxTravelMeters >= 0.05 || maxRotationDegrees >= 5
    }

    /// Every T1 check at once.
    var passes: Bool {
        framesReceived > 1
            && framesMissingImage == 0
            && timestampsAlwaysIncrease
            && cameraHasMoved
    }
}

/// Accumulates a `FrameHealthReport` one frame at a time.
struct FrameHealthCheck: Sendable {
    private(set) var report = FrameHealthReport()
    private var firstTransform: simd_float4x4?

    /// Record one frame.
    ///
    /// - Parameters:
    ///   - timestamp: `ARFrame.timestamp`.
    ///   - imageSize: width and height of `ARFrame.capturedImage`.
    ///   - cameraTransform: `ARFrame.camera.transform`.
    mutating func record(
        timestamp: TimeInterval,
        imageSize: (width: Int, height: Int),
        cameraTransform: simd_float4x4
    ) {
        report.framesReceived += 1

        if imageSize.width <= 0 || imageSize.height <= 0 {
            report.framesMissingImage += 1
        }

        if let last = report.lastTimestamp, timestamp <= last {
            report.timestampsAlwaysIncrease = false
        }
        if report.firstTimestamp == nil { report.firstTimestamp = timestamp }
        report.lastTimestamp = timestamp

        guard let first = firstTransform else {
            firstTransform = cameraTransform
            return
        }
        report.maxTravelMeters = max(report.maxTravelMeters, translationDistance(first, cameraTransform))
        report.maxRotationDegrees = max(report.maxRotationDegrees, rotationAngleDegrees(first, cameraTransform))
    }

    /// Start over, e.g. after the session is restarted.
    mutating func reset() {
        self = FrameHealthCheck()
    }
}

/// Straight-line distance between the positions stored in two transforms (column 3).
func translationDistance(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
    let pa = SIMD3(a.columns.3.x, a.columns.3.y, a.columns.3.z)
    let pb = SIMD3(b.columns.3.x, b.columns.3.y, b.columns.3.z)
    return simd_distance(pa, pb)
}

/// Angle of the rotation that takes `a`'s orientation to `b`'s, in degrees.
///
/// For rotation matrices, trace(Rᵀ·R') = 1 + 2·cos(θ), so θ = acos((trace - 1) / 2). The
/// clamp guards against float error pushing the cosine just outside [-1, 1], which would
/// make `acos` return NaN.
func rotationAngleDegrees(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
    func rotation(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
    }
    let relative = rotation(a).transpose * rotation(b)
    let trace = relative.columns.0.x + relative.columns.1.y + relative.columns.2.z
    let cosine = min(max((trace - 1) / 2, -1), 1)
    return acos(cosine) * 180 / .pi
}
