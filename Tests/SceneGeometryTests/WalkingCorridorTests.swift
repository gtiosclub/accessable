import Testing
import simd
@testable import SceneGeometry

@Suite("T9 — walking corridor geometry")
struct WalkingCorridorTests {
    private let corridor = WalkingCorridor(
        origin: .zero,
        forward: [0, 0, -2],
        right: [3, 0, 0],
        width: 1,
        maxDistance: 4
    )

    @Test("the suggested initializer supplies a one-metre, four-metre corridor")
    func initializerDefaults() {
        #expect(corridor.width == 1)
        #expect(corridor.maxDistance == 4)
        #expect(corridor.forward == SIMD3<Float>(0, 0, -1))
        #expect(corridor.right == SIMD3<Float>(1, 0, 0))
    }

    @Test("accepts points in front, including every rectangle boundary")
    func pointsInsideAndOnBoundaries() {
        #expect(corridor.contains([0, 0, 0]))
        #expect(corridor.contains([0, 3, -2]))
        #expect(corridor.contains([-0.5, 0, -2]))
        #expect(corridor.contains([0.5, 0, -2]))
        #expect(corridor.contains([0, 0, -4]))
    }

    @Test("rejects points behind, beyond range, and outside the sides")
    func pointsOutside() {
        #expect(!corridor.contains([0, 0, 0.01]))
        #expect(!corridor.contains([0, 0, -4.01]))
        #expect(!corridor.contains([-0.51, 0, -2]))
        #expect(!corridor.contains([0.51, 0, -2]))
    }

    @Test("invalid geometry and non-finite points do not produce containment")
    func invalidInput() {
        let invalidSize = WalkingCorridor(
            origin: .zero, forward: [0, 0, -1], right: [1, 0, 0], width: 0, maxDistance: 4
        )

        #expect(!invalidSize.contains([0, 0, -1]))
        #expect(!corridor.contains([Float.nan, 0, -1]))
    }

    @Test("skewed lateral axes are made perpendicular to forward")
    func skewedAxesAreOrthogonalized() {
        let skewed = WalkingCorridor(
            origin: .zero,
            forward: [0, 0, -1],
            right: [1, 0, -1],
            width: 1,
            maxDistance: 4
        )

        #expect(abs(simd_dot(skewed.forward, skewed.right)) < 1e-6)
        #expect(skewed.contains([0, 0, -1]))
    }

    @Test("parallel axes receive a perpendicular lateral fallback")
    func parallelAxesUsePerpendicularFallback() {
        let parallel = WalkingCorridor(
            origin: .zero,
            forward: [0, 0, -1],
            right: [0, 0, -1],
            width: 1,
            maxDistance: 4
        )

        #expect(abs(simd_dot(parallel.forward, parallel.right)) < 1e-6)
        #expect(parallel.contains([0, 0, -1]))
        #expect(!parallel.contains([0.51, 0, -1]))
    }
}
