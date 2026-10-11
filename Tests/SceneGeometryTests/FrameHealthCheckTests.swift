import Foundation
import Testing
import simd
@testable import SceneGeometry

@Suite("T1 — shared camera session health checks")
struct FrameHealthCheckTests {
    /// A camera at `position`, turned `yawDegrees` about world +Y.
    private func pose(position: SIMD3<Float> = .zero, yawDegrees: Float = 0) -> simd_float4x4 {
        let rotation = simd_float4x4(simd_quatf(angle: yawDegrees * .pi / 180, axis: SIMD3(0, 1, 0)))
        var transform = rotation
        transform.columns.3 = SIMD4(position, 1)
        return transform
    }

    private let image = (width: 1920, height: 1440)

    @Test("a healthy session that moves passes every check")
    func healthySessionPasses() {
        var check = FrameHealthCheck()
        for i in 0..<60 {
            check.record(
                timestamp: Double(i) / 60,
                imageSize: image,
                cameraTransform: pose(position: SIMD3(0, 0, -Float(i) * 0.01))
            )
        }

        let report = check.report
        #expect(report.framesReceived == 60)
        #expect(report.framesMissingImage == 0)
        #expect(report.timestampsAlwaysIncrease)
        #expect(report.cameraHasMoved)
        #expect(report.passes)
        #expect(abs((report.averageFPS ?? 0) - 60) < 0.01)
    }

    @Test("a camera that never moves does not pass")
    func stuckTransformFails() {
        var check = FrameHealthCheck()
        for i in 0..<30 {
            check.record(timestamp: Double(i) / 30, imageSize: image, cameraTransform: matrix_identity_float4x4)
        }
        #expect(!check.report.cameraHasMoved)
        #expect(!check.report.passes)
    }

    @Test("turning in place counts as movement")
    func rotationCountsAsMovement() {
        var check = FrameHealthCheck()
        check.record(timestamp: 0, imageSize: image, cameraTransform: pose())
        check.record(timestamp: 0.1, imageSize: image, cameraTransform: pose(yawDegrees: 30))

        #expect(abs(check.report.maxRotationDegrees - 30) < 0.1)
        #expect(check.report.maxTravelMeters < 1e-5)
        #expect(check.report.cameraHasMoved)
    }

    @Test("a repeated or backwards timestamp is caught")
    func nonIncreasingTimestampFails() {
        var check = FrameHealthCheck()
        check.record(timestamp: 1.0, imageSize: image, cameraTransform: pose())
        check.record(timestamp: 1.0, imageSize: image, cameraTransform: pose(position: SIMD3(1, 0, 0)))
        #expect(!check.report.timestampsAlwaysIncrease)
        #expect(!check.report.passes)
    }

    @Test("an empty image is counted")
    func emptyImageIsCounted() {
        var check = FrameHealthCheck()
        check.record(timestamp: 0, imageSize: (0, 0), cameraTransform: pose())
        check.record(timestamp: 0.1, imageSize: image, cameraTransform: pose(position: SIMD3(1, 0, 0)))
        #expect(check.report.framesMissingImage == 1)
        #expect(!check.report.passes)
    }

    @Test("FPS is unknown until there are two frames")
    func fpsNeedsTwoFrames() {
        var check = FrameHealthCheck()
        #expect(check.report.averageFPS == nil)
        check.record(timestamp: 0, imageSize: image, cameraTransform: pose())
        #expect(check.report.averageFPS == nil)
    }

    @Test("reset clears everything")
    func resetClears() {
        var check = FrameHealthCheck()
        check.record(timestamp: 0, imageSize: image, cameraTransform: pose())
        check.reset()
        #expect(check.report == FrameHealthReport())
    }
}
