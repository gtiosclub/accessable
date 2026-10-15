import Testing
import simd
@testable import SceneGeometry

@Suite("T9 — walking corridor geometry")
struct WalkingCorridorTests {
    private let corridor = WalkingCorridor(
        origin: .zero,
        forward: [0, 0, -2],
        right: [3, 0, 0]
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
        #expect(contains(point: [0, 0, 0], corridor: corridor))
        #expect(contains(point: [0, 3, -2], corridor: corridor))
        #expect(contains(point: [-0.5, 0, -2], corridor: corridor))
        #expect(contains(point: [0.5, 0, -2], corridor: corridor))
        #expect(contains(point: [0, 0, -4], corridor: corridor))
    }

    @Test("rejects points behind, beyond range, and outside the sides")
    func pointsOutside() {
        #expect(!contains(point: [0, 0, 0.01], corridor: corridor))
        #expect(!contains(point: [0, 0, -4.01], corridor: corridor))
        #expect(!contains(point: [-0.51, 0, -2], corridor: corridor))
        #expect(!contains(point: [0.51, 0, -2], corridor: corridor))
    }

    @Test("invalid geometry and non-finite points do not produce containment")
    func invalidInput() {
        let invalidSize = WalkingCorridor(
            origin: .zero, forward: [0, 0, -1], right: [1, 0, 0], width: 0, maxDistance: 4
        )

        #expect(!contains(point: [0, 0, -1], corridor: invalidSize))
        #expect(!contains(point: [Float.nan, 0, -1], corridor: corridor))
    }

    @Test("skewed lateral axes are made perpendicular to forward")
    func skewedAxesAreOrthogonalized() {
        let skewed = WalkingCorridor(
            origin: .zero,
            forward: [0, 0, -1],
            right: [1, 0, -1]
        )

        #expect(abs(simd_dot(skewed.forward, skewed.right)) < 1e-6)
        #expect(contains(point: [0, 0, -1], corridor: skewed))
    }

    @Test("parallel axes receive a perpendicular lateral fallback")
    func parallelAxesUsePerpendicularFallback() {
        let parallel = WalkingCorridor(
            origin: .zero,
            forward: [0, 0, -1],
            right: [0, 0, -1]
        )

        #expect(abs(simd_dot(parallel.forward, parallel.right)) < 1e-6)
        #expect(contains(point: [0, 0, -1], corridor: parallel))
        #expect(!contains(point: [0.51, 0, -1], corridor: parallel))
    }
}
