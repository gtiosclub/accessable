import Foundation
import simd

// Label-free obstacle detection (1.1 / task T11).
//
// Anything that rises off the detected floor inside the walking corridor is an obstacle,
// whether or not an object-detection model recognizes it. That is the point: the model
// has a fixed vocabulary, and the things people trip over mostly aren't in it.

/// Knobs for `detectObstacles`, in metres.
struct ObstacleDetectionTuning: Sendable {
    /// Points within this distance of the floor plane are the floor itself. Also drops
    /// points below it — a hole in the ground is task T12's problem, not an obstacle.
    var floorTolerance: Float = 0.06
    /// A cluster's top must clear this to count. 0.20 m rather than the 0.50 m in the
    /// task sheet: a low box or a bollard base is a genuine trip hazard, and anything
    /// taller than this is caught too.
    var minObstacleHeight: Float = 0.20
    /// Ignore everything above head height — ceilings, awnings, overhead signage — so
    /// an indoor scene doesn't report its own ceiling as an obstacle.
    var maxObstacleHeight: Float = 2.20
    /// Two points within this distance of each other, measured in the floor-plane
    /// footprint, belong to the same object.
    var clusterRadius: Float = 0.12
    /// Clusters smaller than this are depth speckle, not objects.
    var minClusterPoints: Int = 8

    static let `default` = ObstacleDetectionTuning()

    init() {}
}

/// Finds obstacles in `points` by height above `floor`, and reports which of them stand
/// in the user's way.
///
/// Returns every cluster it finds, each flagged with whether it intersects the corridor,
/// sorted nearest-first. Filtering down to the actionable ones is the caller's decision.
func detectObstacles(
    points: [SIMD3<Float>],
    floor: Plane3D,
    corridor: WalkingCorridor,
    tuning: ObstacleDetectionTuning = .default
) -> [GeometricObstacle] {
    guard let corridor = corridor.flattened(ontoFloorNormal: floor.normal) else { return [] }

    // 1-2. Height above the floor, keeping only what stands between ankle and head height.
    var kept: [SIMD3<Float>] = []
    var heights: [Float] = []
    for point in points {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { continue }
        let height = distanceFromPlane(point: point, plane: floor)
        guard height > tuning.floorTolerance, height <= tuning.maxObstacleHeight else { continue }
        kept.append(point)
        heights.append(height)
    }
    guard kept.count >= tuning.minClusterPoints else { return [] }

    // 3. Project into the corridor's floor-plane frame: distance along the path, and
    // lateral offset from its centre line.
    var footprints: [SIMD2<Float>] = []
    footprints.reserveCapacity(kept.count)
    for point in kept {
        let offset = point - corridor.origin
        footprints.append(SIMD2(simd_dot(offset, corridor.forward), simd_dot(offset, corridor.right)))
    }

    // 4. Cluster on the 2D footprint, with height carried as an attribute rather than as
    // a third clustering dimension. A sign on a pole, or a chair's seat and its legs,
    // should come back as ONE obstacle with one footprint — that is what a walker has to
    // go around.
    let clusters = clusterFootprints(footprints, radius: tuning.clusterRadius)

    var obstacles: [GeometricObstacle] = []
    for cluster in clusters {
        // 5. Reject speckle and anything too low to matter.
        guard cluster.count >= tuning.minClusterPoints else { continue }
        let topHeight = cluster.map { heights[$0] }.max() ?? 0
        guard topHeight >= tuning.minObstacleHeight else { continue }

        // 6. Describe the cluster.
        var centroid = SIMD3<Float>.zero
        var nearest = Float.greatestFiniteMagnitude
        var minLateral = Float.greatestFiniteMagnitude
        var maxLateral = -Float.greatestFiniteMagnitude
        var intersects = false

        for index in cluster {
            centroid += kept[index]
            nearest = min(nearest, simd_length(kept[index] - corridor.origin))
            let footprint = footprints[index]
            minLateral = min(minLateral, footprint.y)
            maxLateral = max(maxLateral, footprint.y)
            // 7. Inside the corridor rectangle: ahead of the user, not past the horizon
            // we care about, and within half a width of the centre line.
            if footprint.x >= 0, footprint.x <= corridor.maxDistance,
               abs(footprint.y) <= corridor.width / 2 {
                intersects = true
            }
        }
        centroid /= Float(cluster.count)

        obstacles.append(
            GeometricObstacle(
                center: centroid,
                nearestDistance: nearest,
                width: maxLateral - minLateral,
                height: topHeight,
                intersectsWalkingCorridor: intersects
            )
        )
    }

    // 8. Nearest first — the order guidance wants to speak them in.
    return obstacles.sorted { $0.nearestDistance < $1.nearestDistance }
}

/// Single-link clustering of 2D footprints, accelerated by a uniform grid whose cell size
/// is the link radius, so only the 3x3 neighbouring cells need checking.
///
/// Returns point indices grouped by cluster. Points are visited in input order and the
/// neighbour sweep is in a fixed order, so both cluster membership and cluster ordering
/// are deterministic for a given input — dictionary iteration order is never relied on.
func clusterFootprints(_ footprints: [SIMD2<Float>], radius: Float) -> [[Int]] {
    guard !footprints.isEmpty else { return [] }

    struct GridKey: Hashable {
        let a: Int
        let b: Int
    }

    let cell = max(radius, 1e-4)
    func key(_ point: SIMD2<Float>) -> GridKey {
        GridKey(a: Int((point.x / cell).rounded(.down)), b: Int((point.y / cell).rounded(.down)))
    }

    var grid: [GridKey: [Int]] = [:]
    for (index, footprint) in footprints.enumerated() {
        grid[key(footprint), default: []].append(index)
    }

    let radiusSquared = radius * radius
    var visited = [Bool](repeating: false, count: footprints.count)
    var clusters: [[Int]] = []

    for seed in footprints.indices where !visited[seed] {
        visited[seed] = true
        var stack = [seed]
        var cluster: [Int] = []

        while let current = stack.popLast() {
            cluster.append(current)
            let currentKey = key(footprints[current])
            for da in -1 ... 1 {
                for db in -1 ... 1 {
                    let neighbours = grid[GridKey(a: currentKey.a + da, b: currentKey.b + db)] ?? []
                    for candidate in neighbours where !visited[candidate] {
                        let delta = footprints[candidate] - footprints[current]
                        if simd_length_squared(delta) <= radiusSquared {
                            visited[candidate] = true
                            stack.append(candidate)
                        }
                    }
                }
            }
        }
        clusters.append(cluster)
    }

    return clusters
}
