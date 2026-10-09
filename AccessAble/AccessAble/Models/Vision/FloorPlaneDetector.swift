import Foundation
import simd

// Floor/ground plane fitting from a raw 3D point cloud (1.1 / task T10).
//
// Deliberately free of ARKit: the input is plain `[SIMD3<Float>]`, so this can be driven
// from an ARKit mesh, a depth-map unprojection, or a synthetic cloud in a test.

/// Knobs for `detectFloorPlane`. Defaults are tuned for an ARKit point cloud of an
/// indoor or sidewalk scene, in metres.
struct FloorDetectionTuning: Sendable {
    /// Number of RANSAC trials. 200 finds a floor occupying ~20% of the cloud with
    /// very high probability while staying well under a frame budget.
    var iterations: Int = 200
    /// A point within this perpendicular distance of a candidate plane supports it.
    /// ±3 cm covers LiDAR noise at a few metres without swallowing a curb.
    var inlierDistance: Float = 0.03
    /// Absolute floor on support, so a 3-point fluke is never returned.
    var minInliers: Int = 16
    /// Support required as a fraction of the finite input points.
    var minInlierRatio: Float = 0.20
    /// Which way is up. Pass ARKit's gravity-aligned world up, or the device's gravity
    /// vector negated. Only its direction matters.
    var upHint: SIMD3<Float> = [0, 1, 0]
    /// Candidate planes tilted further than this from `upHint` are rejected, which is
    /// what keeps walls and steep banks out of the answer. 25° still accepts ramps.
    var maxTiltDegrees: Float = 25
    /// How much support a lower plane needs before it beats a better-supported higher
    /// one, as a fraction of the best candidate's inlier count. At 0.5 a tabletop has to
    /// be more than twice as well-covered as the floor to win — which encodes the real
    /// prior that the surface you are standing on is the lowest level one in view.
    var lowerPlaneSupportFraction: Float = 0.5
    /// Fixed seed, so the same cloud always produces the same plane and tests are
    /// reproducible. Vary it only if you want to measure fit stability.
    var seed: UInt64 = 0x5EED_5EED

    static let `default` = FloorDetectionTuning()

    init() {}
}

/// The fitted plane plus how well the cloud supported it, so callers can decide whether
/// to trust it before building guidance on top.
struct FloorPlaneFit: Sendable {
    let plane: Plane3D
    /// Points within `inlierDistance` of `plane`.
    let inlierCount: Int
    /// `inlierCount` as a fraction of the finite input points, 0...1.
    let inlierRatio: Float
    /// Root-mean-square perpendicular distance of the inliers, in metres. Small means a
    /// genuinely flat surface; large means we fit a plane to something lumpy.
    let rmsError: Float
}

/// Finds the plane in `points` most likely to be the floor, by RANSAC plus a
/// least-squares refinement over the supporting points.
///
/// Returns nil when no roughly-horizontal plane has enough support — pointing the camera
/// at a wall, at the sky, or at too few points.
func detectFloorPlane(
    points: [SIMD3<Float>],
    tuning: FloorDetectionTuning = .default
) -> FloorPlaneFit? {
    // Depth maps produce holes, which unproject to NaN/inf. Drop them once, up front.
    let finite = points.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
    guard finite.count >= 3 else { return nil }

    let up = simd_normalize(tuning.upHint)
    let minTiltCosine = cos(tuning.maxTiltDegrees * .pi / 180)
    var rng = SplitMix64(seed: tuning.seed)

    struct Candidate {
        let plane: Plane3D
        let inlierCount: Int
    }
    var candidates: [Candidate] = []

    for _ in 0 ..< tuning.iterations {
        guard let (a, b, c) = rng.threeDistinctIndices(below: finite.count) else { break }
        let p0 = finite[a], p1 = finite[b], p2 = finite[c]

        let cross = simd_cross(p1 - p0, p2 - p0)
        // Collinear or coincident sample: no plane through it.
        guard simd_length(cross) > 1e-6 else { continue }

        let normal = simd_normalize(cross)
        // Reject anything that isn't roughly level. abs() because the triangle's winding
        // decides the sign, not the geometry.
        guard abs(simd_dot(normal, up)) >= minTiltCosine else { continue }

        let plane = Plane3D(normal: normal, point: p0)
        var inliers = 0
        for point in finite where abs(distanceFromPlane(point: point, plane: plane)) <= tuning.inlierDistance {
            inliers += 1
        }
        guard inliers >= tuning.minInliers else { continue }
        candidates.append(Candidate(plane: plane, inlierCount: inliers))
    }

    guard let bestCount = candidates.map(\.inlierCount).max() else { return nil }

    // Select after the loop rather than inside it, so the tie-break is explicit: among
    // candidates with enough support, take the LOWEST plane. A large tabletop easily
    // out-votes a partly-occluded floor on inlier count alone, and "lowest wins" is what
    // resolves it.
    let threshold = Int((Float(bestCount) * tuning.lowerPlaneSupportFraction).rounded(.down))
    let contenders = candidates.filter { $0.inlierCount >= threshold }
    guard let winner = contenders.min(by: {
        $0.plane.elevation(along: up) < $1.plane.elevation(along: up)
    }) else { return nil }

    // Refine on the winner's support set. The raw 3-point plane is only as good as the
    // three points that happened to be drawn; a least-squares fit uses all of them.
    let inlierPoints = finite.filter {
        abs(distanceFromPlane(point: $0, plane: winner.plane)) <= tuning.inlierDistance
    }
    let refined = fitPlaneLeastSquares(points: inlierPoints, orientedTowards: up) ?? winner.plane

    // Re-measure support against the refined plane; it has moved, if only slightly.
    var finalInliers: [Float] = []
    for point in finite {
        let d = distanceFromPlane(point: point, plane: refined)
        if abs(d) <= tuning.inlierDistance { finalInliers.append(d) }
    }
    let count = finalInliers.count
    let ratio = Float(count) / Float(finite.count)
    guard count >= tuning.minInliers, ratio >= tuning.minInlierRatio else { return nil }

    let rms = (finalInliers.reduce(0) { $0 + $1 * $1 } / Float(count)).squareRoot()
    return FloorPlaneFit(plane: refined, inlierCount: count, inlierRatio: ratio, rmsError: rms)
}

/// Least-squares plane through `points`: the plane through their centroid whose normal is
/// the direction of least variance. Returns nil for fewer than 3 points or a degenerate
/// (collinear) set. `normal` is flipped into `orientedTowards`'s hemisphere.
func fitPlaneLeastSquares(
    points: [SIMD3<Float>],
    orientedTowards up: SIMD3<Float> = [0, 1, 0]
) -> Plane3D? {
    guard points.count >= 3 else { return nil }

    var centroid = SIMD3<Float>.zero
    for point in points { centroid += point }
    centroid /= Float(points.count)

    // Covariance of the centred points, as a symmetric 3x3.
    var covariance = [[Float]](repeating: [Float](repeating: 0, count: 3), count: 3)
    for point in points {
        let d = point - centroid
        let v = [d.x, d.y, d.z]
        for row in 0 ..< 3 {
            for column in 0 ..< 3 {
                covariance[row][column] += v[row] * v[column]
            }
        }
    }

    let (values, vectors) = symmetricEigenDecomposition3x3(covariance)
    var smallest = 0
    for index in 1 ..< 3 where values[index] < values[smallest] { smallest = index }

    let normal = SIMD3<Float>(vectors[0][smallest], vectors[1][smallest], vectors[2][smallest])
    guard simd_length(normal) > 1e-6 else { return nil }

    let oriented = simd_dot(normal, up) < 0 ? -normal : normal
    return Plane3D(normal: oriented, point: centroid)
}

/// Eigen-decomposition of a symmetric 3x3 matrix by cyclic Jacobi rotations, returning
/// (eigenvalues, eigenvectors-as-columns).
///
/// Jacobi rather than the analytic cubic or an inverse-iteration scheme: a perfectly flat
/// plane gives a covariance with a near-zero smallest eigenvalue, where both of those are
/// numerically fragile. Jacobi stays stable there, and it is deterministic.
func symmetricEigenDecomposition3x3(_ matrix: [[Float]]) -> (values: [Float], vectors: [[Float]]) {
    var a = matrix
    var v: [[Float]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    let pairs = [(0, 1), (0, 2), (1, 2)]

    for _ in 0 ..< 24 {
        // Stop once the off-diagonal mass is negligible.
        let offDiagonal = pairs.reduce(Float(0)) { $0 + abs(a[$1.0][$1.1]) }
        if offDiagonal < 1e-12 { break }

        for (p, q) in pairs {
            let apq = a[p][q]
            if abs(apq) < 1e-12 { continue }

            // Rotation that zeroes a[p][q].
            let theta = (a[q][q] - a[p][p]) / (2 * apq)
            let t = (theta >= 0 ? Float(1) : Float(-1)) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot()
            let s = t * c

            for k in 0 ..< 3 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
            }
            for k in 0 ..< 3 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
            for k in 0 ..< 3 {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
        }
    }

    return ([a[0][0], a[1][1], a[2][2]], v)
}

/// SplitMix64. A seeded generator so RANSAC is reproducible run to run — the system RNG
/// would make every test flaky and every bug report unrepeatable.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform-ish in `0..<n`. The modulo bias is irrelevant at the sizes involved here.
    mutating func nextIndex(below n: Int) -> Int {
        n <= 0 ? 0 : Int(next() % UInt64(n))
    }

    /// Three distinct indices, or nil if `n < 3`.
    mutating func threeDistinctIndices(below n: Int) -> (Int, Int, Int)? {
        guard n >= 3 else { return nil }
        let a = nextIndex(below: n)
        var b = nextIndex(below: n)
        while b == a { b = nextIndex(below: n) }
        var c = nextIndex(below: n)
        while c == a || c == b { c = nextIndex(below: n) }
        return (a, b, c)
    }
}
