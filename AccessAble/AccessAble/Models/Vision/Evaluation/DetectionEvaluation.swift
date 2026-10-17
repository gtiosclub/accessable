import CoreGraphics
import Foundation

// Precision and recall of the object detectors against labelled frames (task T20).

struct GroundTruthDetection: Equatable, Sendable {
    let label: String
    /// Normalized, upright, top-left origin, like `Detection.boundingBox`.
    let boundingBox: CGRect
}

struct DetectionTestCase: Sendable {
    let expected: [GroundTruthDetection]
    let predicted: [Detection]
}

struct DetectionMetrics: Equatable, Sendable {
    let truePositives: Int
    let falsePositives: Int
    let falseNegatives: Int
    /// 1 when nothing was predicted.
    let precision: Float
    /// 1 when nothing was expected.
    let recall: Float
}

/// Scores predictions against ground truth. Predictions are taken most confident first, and
/// each claims the best-overlapping unclaimed ground-truth box with the same label
/// (case-insensitive) and at least `iouThreshold` IoU; a second prediction of the same
/// object counts as a false positive.
func evaluateDetections(_ cases: [DetectionTestCase], iouThreshold: CGFloat = 0.5) -> DetectionMetrics {
    var truePositives = 0, falsePositives = 0, falseNegatives = 0

    for testCase in cases {
        var unmatched = testCase.expected
        for prediction in testCase.predicted.sorted(by: { $0.confidence > $1.confidence }) {
            let best = unmatched.indices
                .filter { unmatched[$0].label.lowercased() == prediction.label.lowercased() }
                .map { ($0, unmatched[$0].boundingBox.intersectionOverUnion(with: prediction.boundingBox)) }
                .filter { $0.1 >= iouThreshold }
                .max { $0.1 < $1.1 }

            if let best {
                unmatched.remove(at: best.0)
                truePositives += 1
            } else {
                falsePositives += 1
            }
        }
        falseNegatives += unmatched.count
    }

    let predicted = truePositives + falsePositives
    let expected = truePositives + falseNegatives
    return DetectionMetrics(
        truePositives: truePositives,
        falsePositives: falsePositives,
        falseNegatives: falseNegatives,
        precision: predicted == 0 ? 1 : Float(truePositives) / Float(predicted),
        recall: expected == 0 ? 1 : Float(truePositives) / Float(expected)
    )
}

func evaluateDetections(_ testCase: DetectionTestCase, iouThreshold: CGFloat = 0.5) -> DetectionMetrics {
    evaluateDetections([testCase], iouThreshold: iouThreshold)
}
