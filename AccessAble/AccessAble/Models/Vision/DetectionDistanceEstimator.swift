import CoreGraphics
import Foundation

// Estimating an object's distance from the LiDAR readings inside its detection box (T7).

/// Knobs for `estimateDistance`.
struct DistanceEstimationTuning: Sendable {
    /// Do not report a distance unless this many readings survive outlier rejection.
    var minimumValidSampleCount: Int = 9
    /// Samples farther than this many robust standard deviations from the median are
    /// treated as outliers.
    var outlierMADMultiplier: Float = 3
    /// Keeps nearly identical readings from making the outlier threshold exactly zero.
    var minimumOutlierDeviation: Float = 0.02
    /// Fraction of the box's width and height, centred, that is sampled first. A detection
    /// box also contains background (between a chair's legs, beside a person's arms); its
    /// centre is much more likely to be the object. The whole box is only used when the
    /// centre has too few readings.
    var coreFraction: CGFloat = 0.5

    static let `default` = DistanceEstimationTuning()

    init() {}
}

/// Estimates how far away the object in `region` is.
///
/// - Parameters:
///   - region: The object's box in normalized depth-map coordinates (top-left origin), as
///     produced by `sensorRect(fromUpright:)`. Parts outside the map are ignored.
///   - depth: The filtered depth map.
/// - Returns: The median depth along the optical axis in metres, with how many readings
///   supported it and how much they agreed; nil when the box has too little usable depth.
func estimateDistance(
    region: CGRect,
    in depth: DepthMap,
    tuning: DistanceEstimationTuning = .default
) -> DistanceEstimate? {
    let fraction = min(max(tuning.coreFraction, 0), 1)
    let core = region.insetBy(dx: region.width * (1 - fraction) / 2, dy: region.height * (1 - fraction) / 2)

    return robustDistance(depthSamples(in: core, of: depth), tuning: tuning)
        ?? robustDistance(depthSamples(in: region, of: depth), tuning: tuning)
}

/// Every reliable reading whose pixel overlaps `region`.
private func depthSamples(in region: CGRect, of depth: DepthMap) -> [Float] {
    let clipped = region.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard !clipped.isNull, !clipped.isEmpty else { return [] }

    let columns = pixelRange(clipped.minX, clipped.maxX, count: depth.width)
    let rows = pixelRange(clipped.minY, clipped.maxY, count: depth.height)

    var samples: [Float] = []
    samples.reserveCapacity(columns.count * rows.count)
    for row in rows {
        for column in columns {
            if let value = depth[column, row] { samples.append(value) }
        }
    }
    return samples
}

private func pixelRange(_ lower: CGFloat, _ upper: CGFloat, count: Int) -> Range<Int> {
    let start = max(0, min(count, Int((lower * CGFloat(count)).rounded(.down))))
    let end = max(start, min(count, Int((upper * CGFloat(count)).rounded(.up))))
    return start ..< end
}

/// Median after median-absolute-deviation outlier rejection, with the interquartile range
/// of what remains as the spread.
private func robustDistance(_ samples: [Float], tuning: DistanceEstimationTuning) -> DistanceEstimate? {
    guard samples.count >= tuning.minimumValidSampleCount else { return nil }

    let initialMedian = quantile(samples, 0.5)
    let deviation = max(quantile(samples.map { abs($0 - initialMedian) }, 0.5) * 1.4826, tuning.minimumOutlierDeviation)
    let limit = tuning.outlierMADMultiplier * deviation
    let retained = samples.filter { abs($0 - initialMedian) <= limit }
    guard retained.count >= tuning.minimumValidSampleCount else { return nil }

    return DistanceEstimate(
        meters: quantile(retained, 0.5),
        validSampleCount: retained.count,
        spread: quantile(retained, 0.75) - quantile(retained, 0.25)
    )
}
