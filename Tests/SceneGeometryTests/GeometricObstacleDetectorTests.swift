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

    @Test("a wall across the path is one obstacle, named as a wall")
    func wall() throws {
        var noise = NoiseGenerator(seed: 41)
        // Wider than the floor cloud, as a real wall is wider than the view.
        let wall = wallPoints(count: 2500, z: -2, x: -2.5 ... 2.5, noise: &noise)
        let cloud = floorCloud() + wall

        let obstacles = detectObstacles(points: cloud, floor: floor, corridor: corridor)
        let coverage = coverageProfile(points: cloud, floor: floor, corridor: corridor, lookAhead: 2.5)

        #expect(obstacles.count == 1)
        let obstacle = try #require(obstacles.first)
        #expect(obstacle.intersectsWalkingCorridor)
        #expect(abs(obstacle.nearestDistance - 2) < 0.05)
        #expect(abs(obstacle.lateralRange.lowerBound + 2.5) < 0.05)
        #expect(abs(obstacle.lateralRange.upperBound - 2.5) < 0.05)
        #expect(abs(obstacle.forwardRange.lowerBound - 2) < 0.05)
        #expect(obstacle.kind(coverage: coverage?.lateral(at: 2)) == .wall)
    }

    @Test("a wall is still found when no floor is in view, against the remembered floor")
    func wallWithoutVisibleFloor() throws {
        // Standing 1 m from a wall, the camera sees nothing but wall from knee height up.
        var noise = NoiseGenerator(seed: 43)
        let wall = wallPoints(count: 1200, z: -1, x: -0.6 ... 0.6, y: 0.3 ... 2.2, noise: &noise)
        let cameraCorridor = WalkingCorridor(origin: [0, 1.3, 0], forward: [0, 0, -1], right: [1, 0, 0], width: 0.9, maxDistance: 4)

        #expect(detectFloorPlane(points: wall) == nil)
        var memory = FloorMemory()
        let estimate = memory.update(fit: detectFloorPlane(points: wall), cameraPosition: cameraCorridor.origin, at: 0)
        #expect(!estimate.isMeasured)

        let obstacles = detectObstacles(points: wall, floor: estimate.plane, corridor: cameraCorridor)
        let coverage = coverageProfile(points: wall, floor: estimate.plane, corridor: cameraCorridor, lookAhead: 2.5)
        let obstacle = try #require(obstacles.first)
        #expect(obstacles.count == 1)
        #expect(obstacle.intersectsWalkingCorridor)
        #expect(abs(obstacle.nearestDistance - 1) < 0.1)
        #expect(obstacle.kind(coverage: coverage?.lateral(at: 1)) == .wall)
    }

    @Test("obstacles are named by shape", arguments: [
        (width: Float(0.1), height: Float(1.8), kind: GeometricObstacle.Kind.pole),
        (width: Float(0.8), height: Float(0.3), kind: GeometricObstacle.Kind.lowObstacle),
        (width: Float(2.0), height: Float(1.2), kind: GeometricObstacle.Kind.wall),
        (width: Float(0.6), height: Float(0.8), kind: GeometricObstacle.Kind.obstacle),
    ])
    func kinds(width: Float, height: Float, kind: GeometricObstacle.Kind) {
        let obstacle = GeometricObstacle(center: [0, height / 2, -2], nearestDistance: 2, width: width, height: height, intersectsWalkingCorridor: true)
        #expect(obstacle.kind(coverage: -3 ... 3) == kind)
    }

    @Test("a narrow stretch of wall that fills the view is still a wall")
    func wallByCoverage() {
        let stretch = GeometricObstacle(center: [0, 1, -1], nearestDistance: 1, width: 1.0, height: 1.8, intersectsWalkingCorridor: true)
        #expect(stretch.kind(coverage: -0.52 ... 0.52) == .wall)
        #expect(stretch.kind(coverage: -1.5 ... 1.5) == .obstacle)
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
