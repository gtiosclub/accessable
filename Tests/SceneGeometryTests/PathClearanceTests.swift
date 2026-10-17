import Foundation
import Testing
import simd
@testable import SceneGeometry

@Suite("Path planning on the occupancy map")
struct PathClearanceTests {
    private let floor = Plane3D.horizontal(atHeight: 0)
    private let camera: SIMD3<Float> = [0, 1.4, 0]

    private func heading(at origin: SIMD3<Float> = [0, 1.4, 0], yawDegrees: Float = 0) -> WalkingCorridor {
        let yaw = yawDegrees * .pi / 180
        return WalkingCorridor(origin: origin, forward: [sin(yaw), 0, -cos(yaw)], right: [cos(yaw), 0, sin(yaw)], width: 0.9, maxDistance: 4)
    }

    private func box(z: Float, x: ClosedRange<Float>, height: Float = 0.8) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for px in stride(from: x.lowerBound, through: x.upperBound, by: 0.03) {
            for y in stride(from: Float(0.05), through: height, by: 0.05) {
                points.append(SIMD3(px, y, z))
            }
        }
        return points
    }

    /// Floor returns over a patch, as a real scan has everywhere the laser reaches the ground.
    private func floorPatch(x: ClosedRange<Float>, z: ClosedRange<Float>, seed: UInt64 = 61) -> [SIMD3<Float>] {
        var noise = NoiseGenerator(seed: seed)
        let area = (x.upperBound - x.lowerBound) * (z.upperBound - z.lowerBound)
        return planePoints(count: Int(area * 600), height: 0, x: x, z: z, sigma: 0.004, noise: &noise)
    }

    /// A map that has seen `points` three times from the default camera, with the floor in
    /// front of the nearest obstacle line seen too (nothing behind it: the laser stops there).
    private func map(seeing points: [SIMD3<Float>], floorTo nearestZ: Float = -3, extraFloor: [SIMD3<Float>] = []) -> LocalOccupancyMap {
        var map = LocalOccupancyMap()
        let seen = points + floorPatch(x: -1.5 ... 1.5, z: nearestZ + 0.1 ... -0.3) + extraFloor
        for _ in 0 ..< 3 {
            map.integrate(points: seen, floor: floor, cameraPosition: camera, floorIsMeasured: true)
        }
        return map
    }

    @Test("an empty map means the path is clear")
    func empty() {
        let plan = planPath(map: LocalOccupancyMap(), heading: heading())
        #expect(plan.clearDirection == .ahead)
        #expect(plan.blockedDistance == nil)
    }

    @Test("something beside the corridor leaves it clear")
    func besideThePath() {
        let plan = planPath(map: map(seeing: box(z: -1.5, x: 0.7 ... 1.1), floorTo: -1.5), heading: heading())
        #expect(plan.clearDirection == .ahead)
    }

    @Test("a chair right of centre sends the user left, and reports how far away it is")
    func aroundAChair() throws {
        let plan = planPath(map: map(seeing: box(z: -1.5, x: -0.1 ... 0.4), floorTo: -1.5), heading: heading())
        #expect(plan.clearDirection == .left)
        #expect(try #require(plan.sidestep) < 0)
        #expect(abs(try #require(plan.blockedDistance) - 1.5) < 0.15)
    }

    @Test("a chair left of centre sends the user right")
    func aroundAChairOnTheLeft() {
        #expect(planPath(map: map(seeing: box(z: -1.5, x: -0.4 ... 0.1), floorTo: -1.5), heading: heading()).clearDirection == .right)
    }

    @Test("a wall across everything seen is blocked; the turn prefers a side already seen open")
    func wall() {
        // Wall across the whole seen width, and a cabinet close on the left, so the right
        // is the side the scan has shown to be open.
        let wall = box(z: -1.2, x: -2.0 ... 2.0, height: 2.0)
        let cabinet = box(z: -0.6, x: -1.5 ... -0.8, height: 1.0)
        let plan = planPath(map: map(seeing: wall + cabinet, floorTo: -1.2), heading: heading())
        #expect(plan.clearDirection == .blocked)
        #expect(plan.turn == .right)
        #expect(abs((plan.blockedDistance ?? 0) - 1.2) < 0.15)
    }

    @Test("a wall's end that the scan has seen floor past is a way round, not a wall")
    func wallWithSeenEnd() {
        // Wall from far left to 0.6 m right of centre; floor seen beyond its end.
        let wall = box(z: -1.2, x: -2.0 ... 0.6, height: 2.0)
        let beyond = floorPatch(x: 0.7 ... 1.5, z: -3 ... -1.2, seed: 63)
        let plan = planPath(map: map(seeing: wall, floorTo: -1.2, extraFloor: beyond), heading: heading())
        #expect(plan.clearDirection == .right)
    }

    @Test("a sidestep is never offered into space that was never seen")
    func noSidestepIntoUnknown() {
        // The same wall end, but nothing seen beyond it: turn, do not step.
        let wall = box(z: -1.2, x: -2.0 ... 0.6, height: 2.0)
        var map = LocalOccupancyMap()
        let seen = wall + floorPatch(x: -0.5 ... 0.5, z: -1.1 ... -0.3)
        for _ in 0 ..< 3 { map.integrate(points: seen, floor: floor, cameraPosition: camera, floorIsMeasured: true) }
        let plan = planPath(map: map, heading: heading())
        #expect(plan.clearDirection == .blocked)
        #expect(plan.turn == .right)
    }

    @Test("a wall with a gap sends the user through the gap")
    func wallWithGap() {
        let left = box(z: -1.5, x: -2.0 ... -1.0, height: 2.0)
        let right = box(z: -1.5, x: 0.2 ... 2.0, height: 2.0)
        let through = floorPatch(x: -0.9 ... 0.1, z: -3 ... -1.5, seed: 65)
        let plan = planPath(map: map(seeing: left + right, floorTo: -1.5, extraFloor: through), heading: heading())
        #expect(plan.clearDirection == .left)
    }

    @Test("obstacles further than the warning distance do not call for a sidestep yet")
    func farObstacle() {
        let plan = planPath(map: map(seeing: box(z: -2.8, x: -0.3 ... 0.3), floorTo: -2.8), heading: heading())
        #expect(plan.clearDirection == .ahead)
        #expect(abs((plan.blockedDistance ?? 0) - 2.8) < 0.15)
    }

    @Test("the plan is the same after turning away, because the map remembers")
    func remembersAfterTurning() {
        let seen = map(seeing: box(z: -1.5, x: -0.1 ... 0.4), floorTo: -1.5)
        // Turned 90° right, facing open space: clear. Turn back: the chair is still there.
        #expect(planPath(map: seen, heading: heading(yawDegrees: 90)).clearDirection == .ahead)
        #expect(planPath(map: seen, heading: heading()).clearDirection == .left)
    }

    @Test("a turned heading reads the map along the new direction")
    func turnedHeading() {
        // Box to the user's right at 1.5 m.
        let seen = map(seeing: box(z: -0.3, x: 1.3 ... 1.7), floorTo: -3)
        #expect(planPath(map: seen, heading: heading()).clearDirection == .ahead)
        #expect(planPath(map: seen, heading: heading(yawDegrees: 90)).blockedDistance != nil)
    }
}
