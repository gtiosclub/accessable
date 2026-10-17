import Foundation
import Testing
import simd
@testable import SceneGeometry

@Suite("Floor memory — a floor when none is in view")
struct FloorMemoryTests {
    private let camera: SIMD3<Float> = [0, 1.3, 0]

    private func fit(atHeight height: Float) -> FloorPlaneFit {
        FloorPlaneFit(plane: .horizontal(atHeight: height), inlierCount: 500, inlierRatio: 0.3, rmsError: 0.005)
    }

    @Test("a fit this frame is used as measured")
    func measured() {
        var memory = FloorMemory()
        let estimate = memory.update(fit: fit(atHeight: 0), cameraPosition: camera, at: 0)
        #expect(estimate.isMeasured)
        #expect(abs(estimate.cameraHeight - 1.3) < 1e-5)
        #expect(memory.rememberedCameraHeight == 1.3)
    }

    @Test("without a fit, the last plane is reused for a while")
    func remembered() {
        var memory = FloorMemory()
        let measured = memory.update(fit: fit(atHeight: 0.1), cameraPosition: camera, at: 0)
        let remembered = memory.update(fit: nil, cameraPosition: camera, at: 1.0)
        #expect(!remembered.isMeasured)
        #expect(remembered.plane == measured.plane)
        #expect(abs(remembered.cameraHeight - 1.2) < 1e-5)
    }

    @Test("after the hold, a level plane follows the camera at the remembered height")
    func followsTheCamera() {
        var memory = FloorMemory()
        _ = memory.update(fit: fit(atHeight: 0), cameraPosition: camera, at: 0)
        let raised: SIMD3<Float> = [2, 1.5, -3]
        let estimate = memory.update(fit: nil, cameraPosition: raised, at: 5)
        #expect(!estimate.isMeasured)
        #expect(abs(estimate.cameraHeight - 1.3) < 1e-5)
        #expect(abs(distanceFromPlane(point: raised, plane: estimate.plane) - 1.3) < 1e-5)
        #expect(abs(estimate.plane.point.y - 0.2) < 1e-5)
    }

    @Test("before any fit, chest height is assumed")
    func assumed() {
        var memory = FloorMemory()
        let estimate = memory.update(fit: nil, cameraPosition: camera, at: 0)
        #expect(!estimate.isMeasured)
        #expect(estimate.cameraHeight == 1.3)
        #expect(abs(estimate.plane.point.y) < 1e-5)
    }

    @Test("a plane that puts the camera at knee height is not the floor")
    func implausibleRejected() {
        var memory = FloorMemory()
        let estimate = memory.update(fit: fit(atHeight: 1.1), cameraPosition: camera, at: 0)
        #expect(!estimate.isMeasured)
        #expect(memory.rememberedCameraHeight == nil)
    }

    @Test("a sudden jump in height is a glitch until several fits agree on it")
    func jumpNeedsConfirmation() {
        var memory = FloorMemory()
        _ = memory.update(fit: fit(atHeight: 0), cameraPosition: camera, at: 0)
        // One tabletop fit, then a real fit again: the tabletop never gets in.
        let glitch = memory.update(fit: fit(atHeight: 0.6), cameraPosition: camera, at: 0.1)
        #expect(!glitch.isMeasured)
        #expect(abs(glitch.cameraHeight - 1.3) < 1e-5)
        #expect(memory.update(fit: fit(atHeight: 0), cameraPosition: camera, at: 0.2).isMeasured)

        // Five fits in a row at the new height: the user sat down.
        var accepted: [Bool] = []
        for frame in 1 ... 5 {
            accepted.append(memory.update(fit: fit(atHeight: 0.6), cameraPosition: camera, at: 0.2 + Double(frame) * 0.1).isMeasured)
        }
        #expect(accepted == [false, false, false, false, true])
        #expect(memory.rememberedCameraHeight.map { abs($0 - 0.7) < 1e-5 } == true)
    }

    @Test("a gradual change in height is followed without confirmation")
    func gradualChangeFollowed() {
        var memory = FloorMemory()
        var measured = true
        for frame in 0 ..< 10 {
            // Lowering the phone 0.5 m over ten frames, 5 cm at a time.
            measured = measured && memory.update(fit: fit(atHeight: Float(frame) * 0.05), cameraPosition: camera, at: Double(frame) * 0.1).isMeasured
        }
        #expect(measured)
    }

    @Test("reset forgets the floor but keeps the tuning")
    func reset() {
        var memory = FloorMemory()
        memory.defaultCameraHeight = 1.0
        _ = memory.update(fit: fit(atHeight: 0), cameraPosition: camera, at: 0)
        memory.reset()
        #expect(memory.rememberedCameraHeight == nil)
        #expect(memory.update(fit: nil, cameraPosition: camera, at: 0.1).cameraHeight == 1.0)
    }
}
