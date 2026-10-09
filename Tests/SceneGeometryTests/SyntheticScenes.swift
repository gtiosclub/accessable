import Foundation
import simd
@testable import SceneGeometry

// Synthetic scenes for the geometry modules. Everything here is seeded, so a failure is
// always reproducible — a flaky geometry test is worse than no test.

/// Seeded Gaussian noise, built on the same SplitMix64 the detector uses.
struct NoiseGenerator {
    private var rng: SplitMix64

    init(seed: UInt64 = 42) {
        rng = SplitMix64(seed: seed)
    }

    mutating func uniform() -> Float {
        Float(rng.next() >> 11) / Float(1 << 53)
    }

    /// Box-Muller.
    mutating func gaussian(sigma: Float) -> Float {
        let u1 = max(uniform(), 1e-7)
        let u2 = uniform()
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// `count` points scattered on a level plane at `height`, with Gaussian height noise.
func planePoints(
    count: Int,
    height: Float,
    x: ClosedRange<Float> = -2 ... 2,
    z: ClosedRange<Float> = -4 ... 0,
    sigma: Float = 0.01,
    noise: inout NoiseGenerator
) -> [SIMD3<Float>] {
    (0 ..< count).map { _ in
        let px = x.lowerBound + noise.uniform() * (x.upperBound - x.lowerBound)
        let pz = z.lowerBound + noise.uniform() * (z.upperBound - z.lowerBound)
        return SIMD3(px, height + noise.gaussian(sigma: sigma), pz)
    }
}

/// `count` points on a vertical plane at a fixed z (a wall).
func wallPoints(
    count: Int,
    z: Float,
    x: ClosedRange<Float> = -2 ... 2,
    y: ClosedRange<Float> = 0 ... 2.5,
    noise: inout NoiseGenerator
) -> [SIMD3<Float>] {
    (0 ..< count).map { _ in
        let px = x.lowerBound + noise.uniform() * (x.upperBound - x.lowerBound)
        let py = y.lowerBound + noise.uniform() * (y.upperBound - y.lowerBound)
        return SIMD3(px, py, z + noise.gaussian(sigma: 0.01))
    }
}

/// Points on a plane tilted by `degrees` about the X axis — a ramp.
func rampPoints(count: Int, degrees: Float, noise: inout NoiseGenerator) -> [SIMD3<Float>] {
    let slope = tan(degrees * .pi / 180)
    return (0 ..< count).map { _ in
        let px = -2 + noise.uniform() * 4
        let pz = -4 + noise.uniform() * 4
        return SIMD3(px, -pz * slope + noise.gaussian(sigma: 0.005), pz)
    }
}

/// The visible surfaces of an axis-aligned box standing on the floor: the four sides and
/// the top, sampled on a grid. `height` is measured up from y = 0.
func boxSurfacePoints(
    centerX: Float,
    centerZ: Float,
    width: Float,
    depth: Float,
    height: Float,
    step: Float = 0.04,
    minY: Float = 0
) -> [SIMD3<Float>] {
    var points: [SIMD3<Float>] = []
    let xs = Array(stride(from: centerX - width / 2, through: centerX + width / 2, by: step))
    let zs = Array(stride(from: centerZ - depth / 2, through: centerZ + depth / 2, by: step))
    let ys = Array(stride(from: minY, through: height, by: step))

    for x in xs {
        for y in ys {
            points.append(SIMD3(x, y, centerZ - depth / 2))
            points.append(SIMD3(x, y, centerZ + depth / 2))
        }
    }
    for z in zs {
        for y in ys {
            points.append(SIMD3(centerX - width / 2, y, z))
            points.append(SIMD3(centerX + width / 2, y, z))
        }
    }
    for x in xs {
        for z in zs {
            points.append(SIMD3(x, height, z))
        }
    }
    return points
}

/// A height profile sampled every `step` metres, from a function of forward distance.
func groundProfile(
    from: Float,
    to: Float,
    step: Float = 0.05,
    height: (Float) -> Float
) -> [GroundSample] {
    stride(from: from, through: to, by: step).map { distance in
        GroundSample(forwardDistance: distance, height: height(distance))
    }
}

/// A stand-in for `VNHumanObservation`, so the Vision conversion can be tested without a
/// camera or a pixel buffer.
struct StubHumanObservation: HumanRectangleObservation {
    /// Normalized, origin bottom-left, as Vision reports it.
    var boundingBox: CGRect
    var confidence: Float
}
