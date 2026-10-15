import Foundation
import Testing
@testable import SceneGeometry

@Suite("T8 + T20 — distance error and calibration")
struct DistanceEvaluationTests {
    @Test("reports absolute error, RMSE, max error and signed bias")
    func metrics() throws {
        let metrics = try #require(evaluateDistances([
            DistanceTestCase(estimatedMeters: 1.1, actualMeters: 1.0),
            DistanceTestCase(estimatedMeters: 1.8, actualMeters: 2.0),
            DistanceTestCase(estimatedMeters: 3.3, actualMeters: 3.0),
        ]))

        #expect(abs(metrics.meanAbsoluteError - 0.2) < 1e-5)
        #expect(abs(metrics.rootMeanSquaredError - (0.14 / 3).squareRoot()) < 1e-5)
        #expect(abs(metrics.maxAbsoluteError - 0.3) < 1e-5)
        #expect(abs(metrics.meanBias - 0.2 / 3) < 1e-5)
        #expect(metrics.sampleCount == 3)
    }

    @Test("reports signed percentage error")
    func percentageError() throws {
        let percentage = try #require(DistanceTestCase(estimatedMeters: 1.93, actualMeters: 2).percentageError)
        #expect(abs(percentage + 3.5) < 1e-5)
        #expect(DistanceTestCase(estimatedMeters: 1, actualMeters: 0).percentageError == nil)
        #expect(DistanceTestCase(estimatedMeters: .greatestFiniteMagnitude, actualMeters: .leastNonzeroMagnitude).percentageError == nil)
    }

    @Test("ignores unusable cases and returns nil without any usable ones")
    func unusableCases() throws {
        let metrics = try #require(evaluateDistances([
            DistanceTestCase(estimatedMeters: .nan, actualMeters: 2),
            DistanceTestCase(estimatedMeters: 2, actualMeters: .infinity),
            DistanceTestCase(estimatedMeters: 2, actualMeters: 0),
            DistanceTestCase(estimatedMeters: 2.1, actualMeters: 2),
        ]))

        #expect(metrics.sampleCount == 1)
        #expect(abs(metrics.meanAbsoluteError - 0.1) < 1e-6)
        #expect(evaluateDistances([]) == nil)
    }

    @Test("returns nil when the metrics don't fit in a Float")
    func unrepresentableMetrics() {
        #expect(evaluateDistances([
            DistanceTestCase(estimatedMeters: -.greatestFiniteMagnitude, actualMeters: .greatestFiniteMagnitude),
        ]) == nil)
    }

    @Test("fits and applies an affine correction")
    func affineFit() throws {
        let calibration = try #require(fitDistanceCalibration(from: [
            DistanceTestCase(estimatedMeters: 1, actualMeters: 2.5),
            DistanceTestCase(estimatedMeters: 2, actualMeters: 4.5),
            DistanceTestCase(estimatedMeters: 3, actualMeters: 6.5),
        ]))

        #expect(abs(calibration.scale - 2) < 1e-6)
        #expect(abs(calibration.offset - 0.5) < 1e-6)
        let corrected = try #require(calibration.correctedDistance(for: 4))
        #expect(abs(corrected - 8.5) < 1e-6)
    }

    @Test("rejects invalid calibration parameters and non-physical corrections")
    func correctionValidation() throws {
        #expect(DistanceCalibration(scale: .nan, offset: 0) == nil)
        #expect(DistanceCalibration(scale: 1, offset: .infinity) == nil)

        let calibration = try #require(DistanceCalibration(scale: 1, offset: -2))
        #expect(calibration.correctedDistance(for: .nan) == nil)
        #expect(calibration.correctedDistance(for: 0) == nil)
        #expect(calibration.correctedDistance(for: 1) == nil)
        #expect(calibration.correctedDistance(for: 3) == 1)
    }

    @Test("does not fit without varied estimates, or when coefficients overflow Float")
    func degenerateFits() {
        #expect(fitDistanceCalibration(from: [
            DistanceTestCase(estimatedMeters: 2, actualMeters: 2),
            DistanceTestCase(estimatedMeters: 2, actualMeters: 3),
        ]) == nil)
        #expect(fitDistanceCalibration(from: [
            DistanceTestCase(estimatedMeters: 0, actualMeters: 1),
            DistanceTestCase(estimatedMeters: .leastNonzeroMagnitude, actualMeters: .greatestFiniteMagnitude),
        ]) == nil)
    }

    @Test("builds a case straight from a T7 estimate")
    func fromEstimate() {
        let estimate = DistanceEstimate(meters: 1.84, validSampleCount: 126, spread: 0.08)
        #expect(DistanceTestCase(estimate: estimate, actualMeters: 2) == DistanceTestCase(estimatedMeters: 1.84, actualMeters: 2))
    }
}
