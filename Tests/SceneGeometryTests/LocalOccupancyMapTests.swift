import Foundation
import Testing
import simd
@testable import SceneGeometry

@Suite("Occupancy map — remembering what was seen")
struct LocalOccupancyMapTests {
    private let floor = Plane3D.horizontal(atHeight: 0)
    private let camera: SIMD3<Float> = [0, 1.4, 0]

    /// Dense points on a box face across the path at `z`, from the floor up to `height`.
    private func box(z: Float, x: ClosedRange<Float>, height: Float = 0.8) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for px in stride(from: x.lowerBound, through: x.upperBound, by: 0.03) {
            for y in stride(from: Float(0.05), through: height, by: 0.05) {
                points.append(SIMD3(px, y, z))
            }
        }
        return points
    }

    @Test("a box seen twice is occupied; the floor in front of it is free")
    func hitsAndRays() {
        var map = LocalOccupancyMap()
        var noise = NoiseGenerator(seed: 51)
        let floorPoints = planePoints(count: 2000, height: 0, x: -1 ... 1, z: -3 ... -0.3, sigma: 0.004, noise: &noise)
        for _ in 0 ..< 2 {
            map.integrate(points: floorPoints + box(z: -2, x: -0.3 ... 0.3), floor: floor, cameraPosition: camera, floorIsMeasured: true)
        }
        #expect(map.isOccupied(x: 0, z: -2.0))
        #expect(map.isKnownFree(x: 0, z: -1.0))
        #expect(!map.isOccupied(x: 0, z: -2.6)) // behind the box: never seen, not occupied
    }

    @Test("one frame of speckle is not an obstacle")
    func singleHitIgnored() {
        var map = LocalOccupancyMap()
        map.integrate(points: [[0, 0.5, -1.5]], floor: floor, cameraPosition: camera, floorIsMeasured: true)
        #expect(!map.isOccupied(x: 0, z: -1.5))
    }

    @Test("a person who walks away is cleared by the rays that now get past")
    func clearsWhenSeenThrough() {
        var map = LocalOccupancyMap()
        var noise = NoiseGenerator(seed: 53)
        for _ in 0 ..< 3 {
            map.integrate(points: box(z: -1.5, x: -0.2 ... 0.2, height: 1.7), floor: floor, cameraPosition: camera, floorIsMeasured: true)
        }
        #expect(map.isOccupied(x: 0, z: -1.5))
        let farFloor = planePoints(count: 3000, height: 0, x: -0.4 ... 0.4, z: -3 ... -1.6, sigma: 0.004, noise: &noise)
        for _ in 0 ..< 3 {
            map.integrate(points: farFloor, floor: floor, cameraPosition: camera, floorIsMeasured: true)
        }
        #expect(!map.isOccupied(x: 0, z: -1.5))
    }

    @Test("ceiling points say nothing about the floor")
    func ceilingIgnored() {
        var map = LocalOccupancyMap()
        var noise = NoiseGenerator(seed: 55)
        let ceiling = planePoints(count: 2000, height: 2.6, x: -1 ... 1, z: -3 ... -0.3, sigma: 0.004, noise: &noise)
        map.integrate(points: ceiling, floor: floor, cameraPosition: camera, floorIsMeasured: true)
        #expect(!map.hasEvidence)
    }

    @Test("with a remembered floor, only tall things count, so a slightly wrong plane cannot fill the map")
    func uncertainFloor() {
        var map = LocalOccupancyMap()
        // A floor plane 0.2 m too low makes the real floor look 0.2 m high.
        let wrongFloor = Plane3D.horizontal(atHeight: -0.2)
        var noise = NoiseGenerator(seed: 57)
        let floorPoints = planePoints(count: 2000, height: 0, x: -1 ... 1, z: -3 ... -0.3, sigma: 0.004, noise: &noise)
        for _ in 0 ..< 3 {
            map.integrate(points: floorPoints + box(z: -2, x: -0.3 ... 0.3, height: 1.0), floor: wrongFloor, cameraPosition: camera, floorIsMeasured: false)
        }
        #expect(!map.isOccupied(x: 0, z: -1.0))
        #expect(map.isOccupied(x: 0, z: -2.0))
    }

    @Test("the grid follows the camera and keeps what overlaps")
    func recentres() {
        var map = LocalOccupancyMap()
        for _ in 0 ..< 2 {
            map.integrate(points: box(z: -2, x: -0.3 ... 0.3), floor: floor, cameraPosition: camera, floorIsMeasured: true)
        }
        // Walk 5 m sideways; the box is still 2 m in front of where it was.
        map.integrate(points: [], floor: floor, cameraPosition: [5, 1.4, 0], floorIsMeasured: true)
        #expect(map.isOccupied(x: 0, z: -2.0))
        #expect(abs(map.origin.x - (5 - 8)) < 0.2)
    }
}
