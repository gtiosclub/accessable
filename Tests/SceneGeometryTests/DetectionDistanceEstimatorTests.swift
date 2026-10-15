import CoreGraphics
import Testing
@testable import SceneGeometry

@Suite("T7 — detection bounding-box distance")
struct DetectionDistanceEstimatorTests {
    /// A depth map at `background` with a rectangle of pixels at `value`.
    private func depthMap(
        width: Int, height: Int, background: Float,
        patch value: Float? = nil, columns: Range<Int> = 0 ..< 0, rows: Range<Int> = 0 ..< 0
    ) -> DepthMap {
        DepthMap(width: width, height: height) { column, row in
            if let value, columns.contains(column), rows.contains(row) { return value }
            return background
        }
    }

    @Test("reports the median depth and sample count inside the box")
    func medianDistance() throws {
        let depth = depthMap(width: 10, height: 8, background: 4, patch: 1.84, columns: 2 ..< 6, rows: 2 ..< 6)

        let estimate = try #require(estimateDistance(region: CGRect(x: 0.2, y: 0.25, width: 0.4, height: 0.5), in: depth))

        #expect(abs(estimate.meters - 1.84) < 1e-6)
        // The 2x2 centre has too few readings, so the whole 4x4 box is used.
        #expect(estimate.validSampleCount == 16)
        #expect(estimate.spread == 0)
    }

    @Test("prefers the centre of the box over background filling most of it")
    func prefersBoxCentre() throws {
        // A thin object in the middle of its box; 60% of the box is wall 4 m behind it.
        let depth = depthMap(width: 20, height: 20, background: 4, patch: 1.5, columns: 6 ..< 14, rows: 6 ..< 14)

        let estimate = try #require(estimateDistance(region: CGRect(x: 0, y: 0, width: 1, height: 1), in: depth))

        #expect(abs(estimate.meters - 1.5) < 1e-6)
    }

    @Test("rejects isolated extreme readings before measuring distance")
    func rejectsOutliers() throws {
        var tuning = DistanceEstimationTuning.default
        tuning.coreFraction = 1
        let depth = DepthMap(width: 8, height: 8) { column, row in
            switch (column, row) {
            case (0, 0): 0.25
            case (7, 7): 5.5
            default: 1.8
            }
        }

        let estimate = try #require(estimateDistance(region: CGRect(x: 0, y: 0, width: 1, height: 1), in: depth, tuning: tuning))

        #expect(abs(estimate.meters - 1.8) < 1e-6)
        #expect(estimate.validSampleCount == 62)
        #expect(estimate.spread == 0)
    }

    @Test("skips pixels the depth map marks unreliable")
    func skipsUnreliablePixels() throws {
        var tuning = DistanceEstimationTuning.default
        tuning.coreFraction = 1
        let depth = DepthMap(width: 4, height: 4) { column, row in row == 0 && column < 3 ? .nan : 2 }

        let estimate = try #require(estimateDistance(region: CGRect(x: 0, y: 0, width: 1, height: 1), in: depth, tuning: tuning))

        #expect(estimate.validSampleCount == 13)
        #expect(estimate.meters == 2)
    }

    @Test("returns nil when too few usable readings remain")
    func insufficientSamples() {
        let depth = DepthMap(width: 4, height: 4) { column, row in row == 0 && column < 3 ? 1.5 : .nan }
        #expect(estimateDistance(region: CGRect(x: 0, y: 0, width: 1, height: 1), in: depth) == nil)
    }

    @Test("clips an out-of-frame box to valid depth-map pixels")
    func clipsBoundingBox() throws {
        var tuning = DistanceEstimationTuning.default
        tuning.minimumValidSampleCount = 1
        tuning.coreFraction = 1

        let estimate = try #require(estimateDistance(
            region: CGRect(x: -0.2, y: 0.75, width: 0.4, height: 0.5),
            in: .uniform(1.2, width: 10, height: 8),
            tuning: tuning
        ))

        #expect(estimate.validSampleCount == 4)
        #expect(estimate.meters == 1.2)
    }

    @Test("reports interquartile spread after outlier removal")
    func reportsSpread() throws {
        var tuning = DistanceEstimationTuning.default
        tuning.coreFraction = 1
        let columns: [Float] = [1.6, 1.7, 1.8, 1.9]
        let depth = DepthMap(width: 4, height: 4) { column, _ in columns[column] }

        let estimate = try #require(estimateDistance(region: CGRect(x: 0, y: 0, width: 1, height: 1), in: depth, tuning: tuning))

        #expect(abs(estimate.meters - 1.75) < 1e-6)
        #expect(abs(estimate.spread - 0.15) < 1e-6)
    }
}
