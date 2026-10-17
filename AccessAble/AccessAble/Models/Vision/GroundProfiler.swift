import Foundation
import simd

// Extracting the forward ground-height profile that T12 consumes (1.1).
//
// T12 takes `[GroundSample]`, and nothing in the pipeline produced them — this is the
// missing step between a depth point cloud and kerb detection.

/// Knobs for `groundProfile`, in metres.
struct GroundProfileTuning: Sendable {
    /// Width of the strip sampled either side of the corridor's centre line. Narrower than
    /// the corridor itself: we want the surface the user's feet will land on, not the
    /// kerb at the far edge of their path.
    var samplingWidth: Float = 0.6
    /// Distance resolution of the profile. Matches `ElevationTuning.binWidth`.
    var binWidth: Float = 0.10
    /// Bins with fewer points than this are left out, so the profile has an honest hole
    /// rather than a height derived from one stray return. T12 reads those holes as signal.
    var minPointsPerBin: Int = 3
    /// Ignore anything this far above the floor when measuring the ground. Keeps an
    /// obstacle's body, or a passing pedestrian's legs, from being mistaken for a rise in
    /// the pavement, while still letting a kerb or one stair riser (up to 0.19 m) through.
    var maxGroundHeight: Float = 0.30
    /// Nothing nearer than this is profiled: the bottom rows of the frame hold the user's
    /// own feet, whatever they are carrying, and the sparsest, noisiest returns.
    var minimumDistance: Float = 0.5
    /// Points inside a detected obstacle's footprint, padded by this, are left out of the
    /// profile unless they lie on the floor. A chair leg standing in a bin otherwise
    /// outnumbers the floor there and reads as a step up, then a drop.
    var obstaclePadding: Float = 0.05
    /// Points this close to the floor are the floor, even under an obstacle.
    var floorTolerance: Float = 0.06
    /// Which height in each bin counts as "the ground". A low quantile rather than the
    /// minimum: the minimum is whichever single point was noisiest downwards.
    var heightQuantile: Float = 0.20

    static let `default` = GroundProfileTuning()

    init() {}
}

/// Builds a forward height profile of the walking surface from a point cloud.
///
/// Heights are signed distances from `floor`, so a kerb down reads negative — the same
/// convention `GroundSample.height` documents. Output is ordered by distance and may have
/// gaps where the sensor returned nothing. `obstacles` (T11's output for the same cloud)
/// are cut out of the profile so that objects standing on the ground are not read as
/// changes in the ground.
func groundProfile(
    points: [SIMD3<Float>],
    floor: Plane3D,
    corridor: WalkingCorridor,
    excluding obstacles: [GeometricObstacle] = [],
    tuning: GroundProfileTuning = .default
) -> [GroundSample] {
    guard let corridor = corridor.flattened(ontoFloorNormal: floor.normal) else { return [] }
    guard tuning.binWidth > 0 else { return [] }

    // Footprints of the obstacles that touch the sampled strip, padded.
    let halfStrip = tuning.samplingWidth / 2
    let exclusions: [(along: ClosedRange<Float>, lateral: ClosedRange<Float>)] = obstacles.compactMap { obstacle in
        let lateral = (obstacle.lateralRange.lowerBound - tuning.obstaclePadding) ... (obstacle.lateralRange.upperBound + tuning.obstaclePadding)
        guard lateral.lowerBound <= halfStrip, lateral.upperBound >= -halfStrip else { return nil }
        let along = (obstacle.forwardRange.lowerBound - tuning.obstaclePadding) ... (obstacle.forwardRange.upperBound + tuning.obstaclePadding)
        return (along, lateral)
    }

    var bins: [Int: [(along: Float, height: Float)]] = [:]

    for point in points {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { continue }

        let offset = point - corridor.origin
        let along = simd_dot(offset, corridor.forward)
        guard along >= tuning.minimumDistance, along <= corridor.maxDistance else { continue }

        let lateral = simd_dot(offset, corridor.right)
        guard abs(lateral) <= halfStrip else { continue }

        let height = distanceFromPlane(point: point, plane: floor)
        guard height <= tuning.maxGroundHeight else { continue }
        if height > tuning.floorTolerance,
           exclusions.contains(where: { $0.along.contains(along) && $0.lateral.contains(lateral) }) {
            continue
        }

        bins[Int((along / tuning.binWidth).rounded(.down)), default: []].append((along, height))
    }

    return bins.keys.sorted().compactMap { index in
        let bin = bins[index]!
        guard bin.count >= tuning.minPointsPerBin else { return nil }
        return GroundSample(
            forwardDistance: bin.reduce(0) { $0 + $1.along } / Float(bin.count),
            height: quantile(bin.map(\.height), tuning.heightQuantile)
        )
    }
}

/// Linear-interpolation quantile of `values`, with `q` in 0...1. Returns 0 when empty.
func quantile(_ values: [Float], _ q: Float) -> Float {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    guard sorted.count > 1 else { return sorted[0] }

    let position = min(max(q, 0), 1) * Float(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = min(lower + 1, sorted.count - 1)
    let fraction = position - Float(lower)
    return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
}
