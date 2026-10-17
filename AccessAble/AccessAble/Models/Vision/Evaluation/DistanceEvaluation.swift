import Foundation

// How far off T7's distances are from tape-measured ones, and how to correct them
// (tasks T8 and T20).

/// One measured comparison, in metres.
struct DistanceTestCase: Equatable, Sendable {
    let estimatedMeters: Float
    let actualMeters: Float

    init(estimatedMeters: Float, actualMeters: Float) {
        self.estimatedMeters = estimatedMeters
        self.actualMeters = actualMeters
    }

    init(estimate: DistanceEstimate, actualMeters: Float) {
        self.init(estimatedMeters: estimate.meters, actualMeters: actualMeters)
    }

    /// Signed error as a percentage of the actual distance; negative means too short.
    /// nil when the actual distance can't serve as a denominator.
    var percentageError: Float? {
        guard isUsable else { return nil }
        let error = (estimatedMeters - actualMeters) / actualMeters * 100
        return error.isFinite ? error : nil
    }

    /// Finite readings with a positive actual distance.
    fileprivate var isUsable: Bool {
        estimatedMeters.isFinite && actualMeters.isFinite && actualMeters > 0
    }
}

struct DistanceMetrics: Equatable, Sendable {
    /// Mean absolute error, in metres.
    let meanAbsoluteError: Float
    /// Root mean squared error, in metres.
    let rootMeanSquaredError: Float
    /// Largest absolute error, in metres.
    let maxAbsoluteError: Float
    /// Mean signed error, in metres; negative means distances read short.
    let meanBias: Float
    /// Usable cases the metrics were computed from.
    let sampleCount: Int
}

/// Aggregate error over the usable cases (finite, positive actual distance). Returns nil
/// when none are usable or the result doesn't fit in a `Float`.
func evaluateDistances(_ cases: [DistanceTestCase]) -> DistanceMetrics? {
    let usable = cases.filter(\.isUsable)
    guard !usable.isEmpty else { return nil }

    // Accumulate in Double so a large set doesn't lose precision.
    var absoluteSum = 0.0, squaredSum = 0.0, signedSum = 0.0, maxAbsolute = 0.0
    for testCase in usable {
        let error = Double(testCase.estimatedMeters) - Double(testCase.actualMeters)
        signedSum += error
        absoluteSum += abs(error)
        squaredSum += error * error
        maxAbsolute = max(maxAbsolute, abs(error))
    }
    let count = Double(usable.count)
    let values = [absoluteSum / count, (squaredSum / count).squareRoot(), maxAbsolute, signedSum / count].map(Float.init)
    guard values.allSatisfy(\.isFinite) else { return nil }

    return DistanceMetrics(
        meanAbsoluteError: values[0],
        rootMeanSquaredError: values[1],
        maxAbsoluteError: values[2],
        meanBias: values[3],
        sampleCount: usable.count
    )
}

/// An affine correction for systematic distance error:
/// `corrected = scale * measured + offset`.
struct DistanceCalibration: Equatable, Sendable {
    let scale: Float
    let offset: Float

    init?(scale: Float, offset: Float) {
        guard scale.isFinite, offset.isFinite else { return nil }
        self.scale = scale
        self.offset = offset
    }

    /// The corrected distance, or nil for a non-physical input or result.
    func correctedDistance(for measured: Float) -> Float? {
        guard measured.isFinite, measured > 0 else { return nil }
        let corrected = scale * measured + offset
        return corrected.isFinite && corrected > 0 ? corrected : nil
    }
}

/// Least-squares fit of `actual = scale * estimated + offset` over the usable cases.
/// Needs at least two cases with different estimates.
func fitDistanceCalibration(from cases: [DistanceTestCase]) -> DistanceCalibration? {
    let usable = cases.filter(\.isUsable)
    guard usable.count >= 2 else { return nil }

    let count = Double(usable.count)
    let meanEstimated = usable.reduce(0.0) { $0 + Double($1.estimatedMeters) } / count
    let meanActual = usable.reduce(0.0) { $0 + Double($1.actualMeters) } / count

    var covariance = 0.0, variance = 0.0
    for testCase in usable {
        let deviation = Double(testCase.estimatedMeters) - meanEstimated
        covariance += deviation * (Double(testCase.actualMeters) - meanActual)
        variance += deviation * deviation
    }
    guard variance > 0 else { return nil }

    let scale = covariance / variance
    return DistanceCalibration(scale: Float(scale), offset: Float(meanActual - scale * meanEstimated))
}
