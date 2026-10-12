import CoreGraphics
import CoreVideo
import Foundation

// Estimating an object's distance from the LiDAR readings inside its detection box (T7).
// The box is expected to be normalized to the depth map, with a top-left origin. T5 owns
// converting a detection from the RGB camera's coordinate system into that space.

/// Knobs for robust per-detection depth estimation.
struct DistanceEstimationTuning: Sendable {
    /// Readings outside this usable LiDAR range are ignored, in metres.
    var depthRange: ClosedRange<Float> = 0.2 ... 6.0
    /// Do not report a distance unless this many readings survive all filtering.
    var minimumValidSampleCount: Int = 9
    /// Samples farther than this many robust standard deviations from the initial median
    /// are treated as outliers.
    var outlierMADMultiplier: Float = 3
    /// Keeps nearly-identical readings from making the outlier threshold exactly zero.
    var minimumOutlierDeviation: Float = 0.02

    static let `default` = DistanceEstimationTuning()

    init() {}
}

/// Estimates an object's distance from the Float32 depth samples in its bounding box.
///
/// - Parameters:
///   - boundingBox: Normalized depth-map coordinates, with a top-left origin. Values
///     outside the frame are clipped before sampling.
///   - depthMap: A Float32 metric-depth `CVPixelBuffer`, such as `ARDepthData.depthMap`.
///   - tuning: Valid depth range, sample-count, and outlier-rejection settings.
/// - Returns: A median distance plus reliability information, or `nil` when the box has
///   too little usable depth data.
func estimateDistance(
    boundingBox: CGRect,
    depthMap: CVPixelBuffer,
    tuning: DistanceEstimationTuning = .default
) -> DistanceEstimate? {
    let width = CVPixelBufferGetWidth(depthMap)
    let height = CVPixelBufferGetHeight(depthMap)
    guard width > 0, height > 0,
          tuning.minimumValidSampleCount > 0,
          tuning.outlierMADMultiplier >= 0,
          tuning.minimumOutlierDeviation >= 0,
          tuning.depthRange.lowerBound > 0,
          tuning.depthRange.lowerBound <= tuning.depthRange.upperBound
    else { return nil }

    let frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    let clippedBox = boundingBox.standardized.intersection(frame)
    guard !clippedBox.isNull, !clippedBox.isEmpty else { return nil }

    let startColumn = max(0, min(width, Int(floor(clippedBox.minX * CGFloat(width)))))
    let endColumn = max(0, min(width, Int(ceil(clippedBox.maxX * CGFloat(width)))))
    let startRow = max(0, min(height, Int(floor(clippedBox.minY * CGFloat(height)))))
    let endRow = max(0, min(height, Int(ceil(clippedBox.maxY * CGFloat(height)))))
    guard startColumn < endColumn, startRow < endRow else { return nil }

    guard CVPixelBufferLockBaseAddress(depthMap, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
    guard bytesPerRow >= width * MemoryLayout<Float32>.stride else { return nil }

    var samples: [Float] = []
    samples.reserveCapacity((endColumn - startColumn) * (endRow - startRow))

    for row in startRow ..< endRow {
        for column in startColumn ..< endColumn {
            let depth = baseAddress
                .advanced(by: row * bytesPerRow + column * MemoryLayout<Float32>.stride)
                .assumingMemoryBound(to: Float32.self)
                .pointee
            guard depth.isFinite, tuning.depthRange.contains(depth) else { continue }
            samples.append(depth)
        }
    }

    return robustDistanceEstimate(samples: samples, tuning: tuning)
}

private func robustDistanceEstimate(
    samples: [Float],
    tuning: DistanceEstimationTuning
) -> DistanceEstimate? {
    guard samples.count >= tuning.minimumValidSampleCount else { return nil }

    let initialMedian = distanceMedian(samples)
    let deviations = samples.map { abs($0 - initialMedian) }
    let medianAbsoluteDeviation = distanceMedian(deviations)
    let robustDeviation = max(
        medianAbsoluteDeviation * 1.4826,
        tuning.minimumOutlierDeviation
    )
    let maximumDeviation = tuning.outlierMADMultiplier * robustDeviation
    let retained = samples.filter { abs($0 - initialMedian) <= maximumDeviation }

    guard retained.count >= tuning.minimumValidSampleCount else { return nil }
    let sorted = retained.sorted()

    return DistanceEstimate(
        meters: distanceMedian(sorted),
        validSampleCount: sorted.count,
        spread: distanceQuantile(sorted, 0.75) - distanceQuantile(sorted, 0.25)
    )
}

/// Median of non-empty values. For an even count, averages the two central readings.
private func distanceMedian(_ values: [Float]) -> Float {
    distanceQuantile(values.sorted(), 0.5)
}

/// Linearly interpolated quantile for an already sorted, non-empty collection.
private func distanceQuantile(_ sortedValues: [Float], _ fraction: Float) -> Float {
    let position = min(max(fraction, 0), 1) * Float(sortedValues.count - 1)
    let lower = Int(floor(position))
    let upper = Int(ceil(position))
    guard lower != upper else { return sortedValues[lower] }
    let remainder = position - Float(lower)
    return sortedValues[lower] + (sortedValues[upper] - sortedValues[lower]) * remainder
}
