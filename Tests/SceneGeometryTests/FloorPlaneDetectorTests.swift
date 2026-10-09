import Foundation
import Testing
import simd
@testable import SceneGeometry

@Suite("T10 — floor plane detection")
struct FloorPlaneDetectorTests {
    /// Angle between two directions, in degrees.
    private func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        acos(min(max(simd_dot(simd_normalize(a), simd_normalize(b)), -1), 1)) * 180 / .pi
    }

    @Test("fits a noisy flat floor")
    func flatFloor() throws {
        var noise = NoiseGenerator()
        let points = planePoints(count: 200, height: 0, sigma: 0.01, noise: &noise)

        let fit = try #require(detectFloorPlane(points: points))

        #expect(angle(fit.plane.normal, [0, 1, 0]) < 2)
        #expect(abs(fit.plane.point.y) < 0.01)
        #expect(fit.inlierRatio > 0.95)
        #expect(fit.rmsError < 0.015)
    }

    @Test("the normal always points up, so signed distance means what it says")
    func normalOrientation() throws {
        var noise = NoiseGenerator(seed: 7)
        let points = planePoints(count: 200, height: -1.2, sigma: 0.005, noise: &noise)

        let fit = try #require(detectFloorPlane(points: points))

        #expect(fit.plane.normal.y > 0)
        #expect(distanceFromPlane(point: [0, 0, 0], plane: fit.plane) > 1)
        #expect(distanceFromPlane(point: [0, -2, 0], plane: fit.plane) < 0)
    }

    @Test("picks the floor over a better-covered tabletop")
    func floorBeatsTabletop() throws {
        var noise = NoiseGenerator(seed: 11)
        // The table is seen from above and gets more returns than the partly-occluded
        // floor — inlier count alone would pick it.
        let floor = planePoints(count: 260, height: 0, sigma: 0.008, noise: &noise)
        let table = planePoints(
            count: 400, height: 0.75, x: -1 ... 1, z: -2.5 ... -1.5, sigma: 0.008, noise: &noise
        )

        let fit = try #require(detectFloorPlane(points: floor + table))

        #expect(abs(fit.plane.point.y) < 0.02)
        #expect(angle(fit.plane.normal, [0, 1, 0]) < 2)
    }

    @Test("a floor too sparse to trust loses to the tabletop — the documented limit")
    func sparseFloorLoses() throws {
        var noise = NoiseGenerator(seed: 13)
        let floor = planePoints(count: 50, height: 0, sigma: 0.008, noise: &noise)
        let table = planePoints(
            count: 400, height: 0.75, x: -1 ... 1, z: -2.5 ... -1.5, sigma: 0.008, noise: &noise
        )

        let fit = try #require(detectFloorPlane(points: floor + table))

        // With 11% of the cloud, the floor is below both the support fraction and the
        // minimum ratio. Returning the table is the honest answer for this input.
        #expect(abs(fit.plane.point.y - 0.75) < 0.05)
    }

    @Test("accepts a 10-degree ramp but rejects a wall")
    func tiltTolerance() throws {
        var noise = NoiseGenerator(seed: 17)
        let ramp = rampPoints(count: 300, degrees: 10, noise: &noise)
        #expect(detectFloorPlane(points: ramp) != nil)

        var wallNoise = NoiseGenerator(seed: 19)
        let wall = wallPoints(count: 300, z: -2, noise: &wallNoise)
        #expect(detectFloorPlane(points: wall) == nil)
    }

    @Test("survives NaN holes in the depth data")
    func nonFiniteInput() throws {
        var noise = NoiseGenerator(seed: 23)
        var points = planePoints(count: 200, height: 0, sigma: 0.008, noise: &noise)
        points.append(contentsOf: [
            SIMD3(.nan, .nan, .nan),
            SIMD3(0, .infinity, 0),
            SIMD3(1, 0, -.infinity),
        ])

        let fit = try #require(detectFloorPlane(points: points))
        #expect(abs(fit.plane.point.y) < 0.01)
    }

    @Test("degenerate clouds return nil instead of a fake plane", arguments: [
        [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0)],
        Array(repeating: SIMD3<Float>(1, 2, 3), count: 50),
        (0 ..< 50).map { SIMD3<Float>(Float($0) * 0.1, 0, 0) },
    ])
    func degenerateInput(points: [SIMD3<Float>]) {
        #expect(detectFloorPlane(points: points) == nil)
    }

    @Test("same cloud, same plane")
    func deterministic() throws {
        var noise = NoiseGenerator(seed: 29)
        let points = planePoints(count: 300, height: 0.3, sigma: 0.01, noise: &noise)

        let first = try #require(detectFloorPlane(points: points))
        let second = try #require(detectFloorPlane(points: points))

        #expect(first.plane == second.plane)
        #expect(first.inlierCount == second.inlierCount)
    }

    @Test("distanceFromPlane is signed and in metres")
    func signedDistance() {
        let plane = Plane3D.horizontal(atHeight: 0)
        #expect(abs(distanceFromPlane(point: [0, 0.5, 0], plane: plane) - 0.5) < 1e-6)
        #expect(abs(distanceFromPlane(point: [3, -0.2, -7], plane: plane) + 0.2) < 1e-6)
        #expect(abs(distanceFromPlane(point: [1, 0, 1], plane: plane)) < 1e-6)
    }
}
