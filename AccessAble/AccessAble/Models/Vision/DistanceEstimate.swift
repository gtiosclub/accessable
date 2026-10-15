import Foundation

/// A robust metric-distance measurement for one detected object.
///
/// `spread` is the interquartile range of the retained depth samples, in metres. Smaller
/// values mean the samples agreed more closely after invalid readings and outliers were
/// removed.
struct DistanceEstimate: Equatable, Sendable {
    let meters: Float
    let validSampleCount: Int
    let spread: Float
}
