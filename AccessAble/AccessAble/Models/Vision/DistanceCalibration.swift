import Foundation

// Evaluating and correcting the metric distances reported by T7 against measurements made
// in the physical world (T8).

/// One manually measured comparison against a T7 distance estimate, in metres.
struct CalibrationSample: Equatable, Sendable {
    let estimatedMeters: Float
    let groundTruthMeters: Float

    /// Creates a calibration sample directly from T7's robust object-distance result.
    init(estimate: DistanceEstimate, groundTruthMeters: Float) {
        self.estimatedMeters = estimate.meters
        self.groundTruthMeters = groundTruthMeters
    }

    init(estimatedMeters: Float, groundTruthMeters: Float) {
        self.estimatedMeters = estimatedMeters
        self.groundTruthMeters = groundTruthMeters
    }

    /// Signed error relative to the measured distance, as a percentage.
    ///
    /// A negative value means T7 measured too short; `nil` means the ground-truth value
    /// cannot be used as a percentage denominator.
    var percentageError: Float? {
        guard estimatedMeters.isFinite, groundTruthMeters.isFinite, groundTruthMeters > 0 else {
            return nil
        }
        let error = (estimatedMeters - groundTruthMeters) / groundTruthMeters * 100
        return error.isFinite ? error : nil
    }
}

/// Aggregate error measurements for a set of valid calibration samples.
struct CalibrationReport: Equatable, Sendable {
    /// Mean absolute error, in metres.
    let meanAbsoluteError: Float
    /// Root mean squared error, in metres.
    let rootMeanSquaredError: Float
    /// Mean signed error, in metres. Negative values indicate underestimation.
    let meanBias: Float
    /// The number of finite, positive-ground-truth samples included in this report.
    let sampleCount: Int
}

/// An affine correction fitted from calibration samples.
///
/// Apply it as `correctedDistance = scale * measuredDistance + offset`.
struct DistanceCalibration: Equatable, Sendable {
    let scale: Float
    let offset: Float

    init?(scale: Float, offset: Float) {
        guard scale.isFinite, offset.isFinite else { return nil }
        self.scale = scale
        self.offset = offset
    }

    /// Applies this correction to a positive, finite T7 measurement.
    func correctedDistance(for measuredDistance: Float) -> Float? {
        guard measuredDistance.isFinite, measuredDistance > 0 else { return nil }
        let corrected = scale * measuredDistance + offset
        guard corrected.isFinite, corrected > 0 else { return nil }
        return corrected
    }
}

/// Calculates aggregate distance error for manually measured T7 comparisons.
///
/// Non-finite readings and non-positive ground-truth distances are ignored. Returns `nil`
/// when no usable sample remains.
func calibrationReport(for samples: [CalibrationSample]) -> CalibrationReport? {
    let validSamples = validCalibrationSamples(from: samples)
    guard !validSamples.isEmpty else { return nil }

    var absoluteErrorSum: Double = 0
    var squaredErrorSum: Double = 0
    var signedErrorSum: Double = 0

    for sample in validSamples {
        let error = Double(sample.estimatedMeters) - Double(sample.groundTruthMeters)
        signedErrorSum += error
        absoluteErrorSum += abs(error)
        squaredErrorSum += error * error
    }

    let count = Double(validSamples.count)
    let meanAbsoluteError = absoluteErrorSum / count
    let rootMeanSquaredError = (squaredErrorSum / count).squareRoot()
    let meanBias = signedErrorSum / count
    guard meanAbsoluteError.isFinite, rootMeanSquaredError.isFinite, meanBias.isFinite else {
        return nil
    }

    let floatMeanAbsoluteError = Float(meanAbsoluteError)
    let floatRootMeanSquaredError = Float(rootMeanSquaredError)
    let floatMeanBias = Float(meanBias)
    guard floatMeanAbsoluteError.isFinite,
          floatRootMeanSquaredError.isFinite,
          floatMeanBias.isFinite else {
        return nil
    }

    return CalibrationReport(
        meanAbsoluteError: floatMeanAbsoluteError,
        rootMeanSquaredError: floatRootMeanSquaredError,
        meanBias: floatMeanBias,
        sampleCount: validSamples.count
    )
}

/// Fits an affine correction from T7 measurements to ground-truth distances.
///
/// This uses ordinary least squares for `groundTruth = scale * estimated + offset`.
/// At least two samples with differing estimated distances are required.
func fitDistanceCalibration(from samples: [CalibrationSample]) -> DistanceCalibration? {
    let validSamples = validCalibrationSamples(from: samples)
    guard validSamples.count >= 2 else { return nil }

    let count = Double(validSamples.count)
    let meanEstimated = validSamples.reduce(0.0) { $0 + Double($1.estimatedMeters) } / count
    let meanGroundTruth = validSamples.reduce(0.0) { $0 + Double($1.groundTruthMeters) } / count

    var covariance: Double = 0
    var estimatedVariance: Double = 0
    for sample in validSamples {
        let estimatedOffset = Double(sample.estimatedMeters) - meanEstimated
        covariance += estimatedOffset * (Double(sample.groundTruthMeters) - meanGroundTruth)
        estimatedVariance += estimatedOffset * estimatedOffset
    }

    guard estimatedVariance > 0 else { return nil }
    let scale = covariance / estimatedVariance
    let offset = meanGroundTruth - scale * meanEstimated
    guard scale.isFinite, offset.isFinite else { return nil }

    let floatScale = Float(scale)
    let floatOffset = Float(offset)
    guard floatScale.isFinite, floatOffset.isFinite else { return nil }
    return DistanceCalibration(scale: floatScale, offset: floatOffset)
}

private func validCalibrationSamples(from samples: [CalibrationSample]) -> [CalibrationSample] {
    samples.filter {
        $0.estimatedMeters.isFinite && $0.groundTruthMeters.isFinite && $0.groundTruthMeters > 0
    }
}
