import CoreGraphics
import Testing
import simd
@testable import SceneGeometry

@Suite("T7 — placing detections in the world")
struct ObjectLocationTests {
    private let intrinsics = CameraIntrinsics(
        focalX: 50, focalY: 50, principalX: 31.5, principalY: 23.5, imageWidth: 64, imageHeight: 48
    )

    @Test("an object at the image centre lands straight ahead at its depth")
    func centredObject() throws {
        // Camera at the origin with ARKit axes: looking down -Z.
        let position = try #require(worldPosition(
            ofRegion: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            in: .uniform(2, width: 64, height: 48),
            intrinsics: intrinsics,
            cameraTransform: matrix_identity_float4x4
        ))

        #expect(abs(position.x) < 1e-3 && abs(position.y) < 1e-3)
        #expect(abs(position.z + 2) < 1e-3)

        let corridor = WalkingCorridor.default
        #expect(abs(corridor.distance(to: position) - 2) < 1e-3)
        #expect(corridor.bearing(to: position).side == .ahead)
    }

    @Test("an object on the right of the image is to the user's right")
    func objectOnTheRight() throws {
        let position = try #require(worldPosition(
            ofRegion: CGRect(x: 0.85, y: 0.4, width: 0.1, height: 0.2),
            in: .uniform(2, width: 64, height: 48),
            intrinsics: intrinsics,
            cameraTransform: matrix_identity_float4x4
        ))

        let bearing = WalkingCorridor.default.bearing(to: position)
        #expect(bearing.degrees > 15 && bearing.degrees < 45)
    }

    @Test("no position without depth under the box")
    func noDepth() {
        let empty = DepthMap(width: 64, height: 48) { _, _ in .nan }
        #expect(worldPosition(
            ofRegion: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            in: empty, intrinsics: intrinsics, cameraTransform: matrix_identity_float4x4
        ) == nil)
    }
}

@Suite("Corridor handedness")
struct CorridorHandednessTests {
    @Test("flattening keeps the lateral axis pointing to the user's right")
    func flattenedRightPointsRight() throws {
        // A portrait camera tilted down: forward is -Z and downwards, and the camera's own
        // +X runs along the phone's long edge, i.e. vertically.
        let tilted = WalkingCorridor(origin: .zero, forward: [0, -0.5, -1], right: [0, 1, 0], width: 0.9, maxDistance: 4)
        let heading = try #require(tilted.flattened(ontoFloorNormal: [0, 1, 0]))

        #expect(abs(heading.right.x - 1) < 1e-5)
        #expect(heading.bearing(to: [1, 0, -1]).side == .right)
        #expect(heading.bearing(to: [-1, 0, -1]).side == .left)
    }
}
