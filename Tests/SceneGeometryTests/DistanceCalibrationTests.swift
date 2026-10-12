import Foundation
import Testing
@testable import SceneGeometry

@Suite("T8 — LiDAR distance calibration")
struct DistanceCalibrationTests {
    @Test("reports absolute error, RMSE, and signed bias")
    func reportMetrics() throws {
        let report = try #require(calibrationReport(for: [
            CalibrationSample(estimatedMeters: 1.93, groundTruthMeters: 2.00),
            CalibrationSample(estimatedMeters: 3.10, groundTruthMeters: 3.00),
        ]))

        #expect(abs(report.meanAbsoluteError - 0.085) < 1e-6)
        #expect(abs(report.rootMeanSquaredError - 0.08631338) < 1e-6)
        #expect(abs(report.meanBias - 0.015) < 1e-6)
        #expect(report.sampleCount == 2)
    }

    @Test("reports signed percentage error")
    func percentageError() throws {
        let sample = CalibrationSample(estimatedMeters: 1.93, groundTruthMeters: 2)

        let percentage = try #require(sample.percentageError)
        #expect(abs(percentage + 3.5) < 1e-5)
        #expect(CalibrationSample(estimatedMeters: 1, groundTruthMeters: 0).percentageError == nil)
        #expect(CalibrationSample(
            estimatedMeters: .greatestFiniteMagnitude,
            groundTruthMeters: .leastNonzeroMagnitude
        ).percentageError == nil)
    }

    @Test("ignores invalid samples and returns nil without usable measurements")
    func invalidSamples() throws {
        let report = try #require(calibrationReport(for: [
            CalibrationSample(estimatedMeters: .nan, groundTruthMeters: 2),
            CalibrationSample(estimatedMeters: 2, groundTruthMeters: .infinity),
            CalibrationSample(estimatedMeters: 2, groundTruthMeters: 0),
            CalibrationSample(estimatedMeters: 2.1, groundTruthMeters: 2),
        ]))

        #expect(report.sampleCount == 1)
        #expect(abs(report.meanAbsoluteError - 0.1) < 1e-6)
        #expect(calibrationReport(for: []) == nil)
    }

    @Test("returns nil when finite samples produce unrepresentable report metrics")
    func unrepresentableReportMetrics() {
        #expect(calibrationReport(for: [
            CalibrationSample(
                estimatedMeters: -.greatestFiniteMagnitude,
                groundTruthMeters: .greatestFiniteMagnitude
            ),
        ]) == nil)
    }

    @Test("fits and applies an affine correction")
    func affineFit() throws {
        let calibration = try #require(fitDistanceCalibration(from: [
            CalibrationSample(estimatedMeters: 1, groundTruthMeters: 2.5),
            CalibrationSample(estimatedMeters: 2, groundTruthMeters: 4.5),
            CalibrationSample(estimatedMeters: 3, groundTruthMeters: 6.5),
        ]))

        #expect(abs(calibration.scale - 2) < 1e-6)
        #expect(abs(calibration.offset - 0.5) < 1e-6)
        let correctedDistance = try #require(calibration.correctedDistance(for: 4))
        #expect(abs(correctedDistance - 8.5) < 1e-6)
    }

    @Test("rejects invalid calibration parameters and nonphysical corrections")
    func correctionValidation() throws {
        #expect(DistanceCalibration(scale: .nan, offset: 0) == nil)
        #expect(DistanceCalibration(scale: 1, offset: .infinity) == nil)

        let calibration = try #require(DistanceCalibration(scale: 1, offset: -2))
        #expect(calibration.correctedDistance(for: .nan) == nil)
        #expect(calibration.correctedDistance(for: 0) == nil)
        #expect(calibration.correctedDistance(for: -1) == nil)
        #expect(calibration.correctedDistance(for: 1) == nil)
        #expect(calibration.correctedDistance(for: 3) == 1)
    }

    @Test("does not fit a correction without varied measurements")
    func degenerateFit() {
        #expect(fitDistanceCalibration(from: [
            CalibrationSample(estimatedMeters: 2, groundTruthMeters: 2),
            CalibrationSample(estimatedMeters: 2, groundTruthMeters: 3),
        ]) == nil)
    }

    @Test("rejects fitted coefficients that cannot be represented as Float")
    func unrepresentableFit() {
        #expect(fitDistanceCalibration(from: [
            CalibrationSample(estimatedMeters: 0, groundTruthMeters: 1),
            CalibrationSample(
                estimatedMeters: .leastNonzeroMagnitude,
                groundTruthMeters: .greatestFiniteMagnitude
            ),
        ]) == nil)
    }

    @Test("creates calibration samples from T7 estimates")
    func t7Integration() {
        let estimate = DistanceEstimate(meters: 1.84, validSampleCount: 126, spread: 0.08)
        let sample = CalibrationSample(estimate: estimate, groundTruthMeters: 2)

        #expect(sample.estimatedMeters == 1.84)
        #expect(sample.groundTruthMeters == 2)
    }
}
