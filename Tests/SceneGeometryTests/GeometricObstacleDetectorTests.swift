import Foundation
import Testing
import simd
@testable import SceneGeometry

@Suite("T11 — geometric obstacle detection")
struct GeometricObstacleDetectorTests {
    private let floor = Plane3D.horizontal(atHeight: 0)
    private let corridor = WalkingCorridor.default

    private func floorCloud(seed: UInt64 = 3) -> [SIMD3<Float>] {
        var noise = NoiseGenerator(seed: seed)
        return planePoints(count: 600, height: 0, sigma: 0.008, noise: &noise)
    }

    /// A thin post seen only near the ground, and a sign plate seen only high up, with a
    /// 1 m vertical hole between them where the depth sensor got no returns off the
    /// narrow pole. One physical object, two disconnected bands of points.
    private func postWithSignPoints() -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for y in stride(from: Float(0.10), through: 0.40, by: 0.03) {
            points.append(contentsOf: [
                SIMD3(-0.03, y, -2.5), SIMD3(0.03, y, -2.5),
                SIMD3(0, y, -2.53), SIMD3(0, y, -2.47),
            ])
        }
        for x in stride(from: Float(-0.15), through: 0.15, by: 0.03) {
            for y in stride(from: Float(1.40), through: 1.60, by: 0.03) {
                points.append(SIMD3(x, y, -2.5))
            }
        }
        return points
    }

    @Test("finds a box in the path and measures it")
    func boxInPath() throws {
        // The task sheet's own example: a 0.6 m wide, 0.8 m tall box about 1.8 m ahead.
        let box = boxSurfacePoints(
            centerX: 0.1, centerZ: -1.8, width: 0.6, depth: 0.2, height: 0.8
        )

        let obstacles = detectObstacles(points: floorCloud() + box, floor: floor, corridor: corridor)

        #expect(obstacles.count == 1)
        let obstacle = try #require(obstacles.first)
        #expect(abs(obstacle.height - 0.8) < 0.05)
        #expect(abs(obstacle.width - 0.6) < 0.05)
        #expect(abs(obstacle.nearestDistance - 1.7) < 0.05)
        #expect(abs(obstacle.center.x - 0.1) < 0.05)
        #expect(abs(obstacle.center.z + 1.8) < 0.05)
        #expect(obstacle.intersectsWalkingCorridor)
    }

    @Test("the same box off to the side is found but flagged as out of the way")
    func boxBesideThePath() throws {
        let box = boxSurfacePoints(
            centerX: 1.6, centerZ: -1.8, width: 0.6, depth: 0.2, height: 0.8
        )

        let obstacles = detectObstacles(points: floorCloud() + box, floor: floor, corridor: corridor)

        #expect(obstacles.count == 1)
        #expect(try #require(obstacles.first).intersectsWalkingCorridor == false)
    }

    @Test("a 5 cm floor mat is not an obstacle")
    func lowFeatureIgnored() {
        let mat = boxSurfacePoints(
            centerX: 0, centerZ: -1.5, width: 0.8, depth: 0.6, height: 0.05, step: 0.03
        )

        #expect(detectObstacles(points: floorCloud() + mat, floor: floor, corridor: corridor).isEmpty)
    }

    @Test("the ceiling is not an obstacle")
    func ceilingIgnored() {
        var noise = NoiseGenerator(seed: 5)
        let ceiling = planePoints(count: 500, height: 2.5, sigma: 0.008, noise: &noise)

        #expect(detectObstacles(points: floorCloud() + ceiling, floor: floor, corridor: corridor).isEmpty)
    }

    @Test("a post and its sign come back as one obstacle, not two")
    func footprintClusteringMergesVerticalGaps() throws {
        let obstacles = detectObstacles(
            points: floorCloud() + postWithSignPoints(), floor: floor, corridor: corridor
        )

        // Clustering in 3D would split these into two obstacles at the same spot, and the
        // user would be told about one thing twice. Clustering on the floor-plane
        // footprint keeps them together.
        #expect(obstacles.count == 1)
        let obstacle = try #require(obstacles.first)
        #expect(abs(obstacle.height - 1.6) < 0.05)
        #expect(abs(obstacle.width - 0.3) < 0.05)
        #expect(obstacle.intersectsWalkingCorridor)
    }

    @Test("two objects come back separately, nearest first")
    func multipleObstaclesSortedByDistance() {
        let near = boxSurfacePoints(centerX: -0.2, centerZ: -1.2, width: 0.3, depth: 0.3, height: 0.5)
        let far = boxSurfacePoints(centerX: 0.2, centerZ: -3.0, width: 0.3, depth: 0.3, height: 0.9)

        let obstacles = detectObstacles(points: floorCloud() + near + far, floor: floor, corridor: corridor)

        #expect(obstacles.count == 2)
        #expect(obstacles[0].nearestDistance < obstacles[1].nearestDistance)
        #expect(abs(obstacles[0].height - 0.5) < 0.05)
        #expect(abs(obstacles[1].height - 0.9) < 0.05)
    }

    @Test("an empty floor has no obstacles")
    func bareFloor() {
        #expect(detectObstacles(points: floorCloud(), floor: floor, corridor: corridor).isEmpty)
    }

    @Test("skewed, unnormalized corridor axes still work")
    func corridorAxesAreRepaired() throws {
        // What an ARKit camera transform actually looks like: tilted, non-unit, and with
        // a `right` vector that isn't perpendicular to `forward`.
        let messy = WalkingCorridor(
            origin: [0, 1.4, 0],
            forward: [0.05, -0.30, -2.0],
            right: [1.3, 0.2, 0.1],
            width: 0.9,
            maxDistance: 4
        )
        let box = boxSurfacePoints(centerX: 0.1, centerZ: -1.8, width: 0.6, depth: 0.2, height: 0.8)

        let obstacles = detectObstacles(points: floorCloud() + box, floor: floor, corridor: messy)

        #expect(obstacles.count == 1)
        #expect(try #require(obstacles.first).intersectsWalkingCorridor)
    }

    @Test("a corridor pointing straight down has no direction of travel")
    func degenerateCorridor() {
        let downward = WalkingCorridor(
            origin: .zero, forward: [0, -1, 0], right: [1, 0, 0], width: 0.9, maxDistance: 4
        )
        let box = boxSurfacePoints(centerX: 0, centerZ: -1.8, width: 0.6, depth: 0.2, height: 0.8)

        #expect(detectObstacles(points: box, floor: floor, corridor: downward).isEmpty)
    }
}
