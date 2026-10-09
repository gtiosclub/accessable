import Foundation
import Testing
import simd
@testable import SceneGeometry

@Suite("Depth → point cloud → floor/obstacles/hazards")
struct DepthPipelineTests {
    /// A camera 1.4 m up looking straight down. Camera +X maps to world +X, camera -Z
    /// (forward) maps to world -Y, so a constant depth map is a perfectly flat floor.
    private func downwardCamera(height: Float = 1.4) -> simd_float4x4 {
        simd_float4x4(
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 0, -1, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, height, 0, 1)
        )
    }

    /// A camera 1.4 m up looking horizontally along world -Z, which is how the phone is
    /// actually held. Camera axes coincide with world axes.
    private func forwardCamera(height: Float = 1.4) -> simd_float4x4 {
        simd_float4x4(
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, height, 0, 1)
        )
    }

    private let intrinsics = CameraIntrinsics(
        focalX: 50, focalY: 50, principalX: 32, principalY: 24, imageWidth: 64, imageHeight: 48
    )

    @Test("intrinsics rescale to the depth map's resolution")
    func intrinsicsScaling() {
        let full = CameraIntrinsics(
            focalX: 1400, focalY: 1400, principalX: 960, principalY: 720,
            imageWidth: 1920, imageHeight: 1440
        )
        let scaled = full.scaled(toWidth: 256, height: 192)

        #expect(abs(scaled.focalX - 1400 * 256 / 1920) < 0.01)
        #expect(abs(scaled.principalX - 128) < 0.01)
        #expect(abs(scaled.principalY - 96) < 0.01)
        #expect(scaled.imageWidth == 256)
    }

    @Test("a constant depth map under a downward camera unprojects to a flat floor")
    func unprojectsToFloor() throws {
        let points = unprojectDepthMap(
            width: 64, height: 48,
            intrinsics: intrinsics,
            cameraTransform: downwardCamera(),
            depthAt: { _, _ in 1.4 }
        )

        #expect(points.count == 16 * 12)
        // Every point should sit on y = 0, and the detector should agree.
        #expect(points.allSatisfy { abs($0.y) < 1e-4 })

        let fit = try #require(detectFloorPlane(points: points))
        let plane = fit.plane
        #expect(abs(simd_dot(plane.normal, SIMD3<Float>(0, 1, 0)) - 1) < 1e-3)
        #expect(abs(plane.point.y) < 1e-3)
    }

    @Test("pixels with no return or low confidence are skipped")
    func filtersBadPixels() {
        // Half the map has no depth at all, and of the rest only every other row is confident.
        let points = unprojectDepthMap(
            width: 64, height: 48,
            intrinsics: intrinsics,
            cameraTransform: downwardCamera(),
            depthAt: { column, _ in column < 32 ? 1.4 : .nan },
            isConfident: { _, row in row.isMultiple(of: 8) }
        )

        #expect(points.count == 8 * 6)
        #expect(points.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    }

    @Test("depth outside the usable range is discarded")
    func clampsDepthRange() {
        let tooClose = unprojectDepthMap(
            width: 64, height: 48, intrinsics: intrinsics,
            cameraTransform: downwardCamera(), depthAt: { _, _ in 0.05 }
        )
        let tooFar = unprojectDepthMap(
            width: 64, height: 48, intrinsics: intrinsics,
            cameraTransform: downwardCamera(), depthAt: { _, _ in 25 }
        )

        #expect(tooClose.isEmpty)
        #expect(tooFar.isEmpty)
    }

    @Test("a box on the floor survives the whole pipeline as an obstacle")
    func depthToObstacle() throws {
        // Every depth pixel this time, so the floor has the few thousand points a real
        // LiDAR map yields rather than being outnumbered by the box.
        var dense = DepthUnprojectionTuning.default
        dense.sampleStride = 1
        var points = unprojectDepthMap(
            width: 64, height: 48, intrinsics: intrinsics,
            cameraTransform: downwardCamera(), tuning: dense, depthAt: { _, _ in 1.4 }
        )
        points += boxSurfacePoints(centerX: 0.1, centerZ: -1.8, width: 0.6, depth: 0.2, height: 0.8)

        let fit = try #require(detectFloorPlane(points: points))
        let obstacles = detectObstacles(points: points, floor: fit.plane, corridor: .default)

        #expect(obstacles.count == 1)
        let obstacle = try #require(obstacles.first)
        #expect(abs(obstacle.height - 0.8) < 0.06)
        #expect(obstacle.intersectsWalkingCorridor)
    }

    @Test("a level pavement produces a flat profile and no hazards")
    func levelGroundProfile() throws {
        var noise = NoiseGenerator(seed: 31)
        let points = planePoints(count: 4000, height: 0, x: -1 ... 1, z: -4 ... 0, sigma: 0.004, noise: &noise)
        let floor = Plane3D.horizontal(atHeight: 0)

        let profile = groundProfile(points: points, floor: floor, corridor: .default)

        #expect(profile.count > 20)
        #expect(profile.allSatisfy { abs($0.height) < 0.02 })
        #expect(detectElevationHazards(samples: profile).isEmpty)
    }

    @Test("a kerb in the point cloud comes out of T12 as a step down")
    func kerbSurvivesTheProfiler() throws {
        var noise = NoiseGenerator(seed: 37)
        // Pavement to 2 m, then an 18 cm drop into the road.
        let pavement = planePoints(count: 2500, height: 0, x: -1 ... 1, z: -2 ... 0, sigma: 0.004, noise: &noise)
        let road = planePoints(count: 2500, height: -0.18, x: -1 ... 1, z: -4 ... -2.05, sigma: 0.004, noise: &noise)
        let floor = Plane3D.horizontal(atHeight: 0)

        let profile = groundProfile(points: pavement + road, floor: floor, corridor: .default)
        let hazards = detectElevationHazards(samples: profile)

        #expect(hazards.count == 1)
        let hazard = try #require(hazards.first)
        #expect(hazard.type == .stepDown)
        #expect(abs(hazard.heightChange + 0.18) < 0.03)
        #expect(abs(hazard.distance - 2.0) < 0.2)
    }

    @Test("an obstacle's body does not get mistaken for rising ground")
    func obstacleDoesNotPolluteTheProfile() {
        var noise = NoiseGenerator(seed: 41)
        let floorPoints = planePoints(count: 4000, height: 0, x: -1 ... 1, z: -4 ... 0, sigma: 0.004, noise: &noise)
        let box = boxSurfacePoints(centerX: 0, centerZ: -2.0, width: 0.4, depth: 0.4, height: 1.0)
        let floor = Plane3D.horizontal(atHeight: 0)

        let profile = groundProfile(points: floorPoints + box, floor: floor, corridor: .default)

        // The box sits squarely in the sampling strip. The ground under and around it is
        // still flat, and T12 must not report a 1 m step up.
        #expect(profile.allSatisfy { abs($0.height) < 0.05 })
        #expect(detectElevationHazards(samples: profile).isEmpty)
    }

    @Test("quantile interpolates and clamps")
    func quantileBehaviour() {
        #expect(abs(quantile([0, 1, 2, 3, 4], 0.0) - 0) < 1e-6)
        #expect(abs(quantile([0, 1, 2, 3, 4], 0.5) - 2) < 1e-6)
        #expect(abs(quantile([0, 1, 2, 3, 4], 1.0) - 4) < 1e-6)
        #expect(abs(quantile([0, 10], 0.25) - 2.5) < 1e-6)
        #expect(quantile([], 0.5) == 0)
    }
}
