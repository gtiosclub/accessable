import CoreGraphics
import Foundation
import QuartzCore

// T20: evaluation metrics for the CV modules.

// MARK: - Types (from the CV spec)

struct GroundTruthDetection: Equatable, Sendable {
    let label: String
    let boundingBox: CGRect // normalized, top-left origin like Detection
}

struct DetectionTestCase: Sendable {
    let expected: [GroundTruthDetection]
    let predicted: [Detection]
}

struct DetectionMetrics: Equatable, Sendable {
    let truePositives: Int
    let falsePositives: Int
    let falseNegatives: Int
    let precision: Float
    let recall: Float
}

struct DistanceTestCase: Equatable, Sendable {
    let estimatedMeters: Float
    let actualMeters: Float
}

struct DistanceMetrics: Equatable, Sendable {
    let meanAbsoluteError: Float
    let rootMeanSquaredError: Float
    let maxAbsoluteError: Float
}

struct FrameTiming: Equatable, Sendable {
    let timestamp: TimeInterval
    let processingMilliseconds: Double
}

struct PerformanceMetrics: Equatable, Sendable {
    let averageFPS: Double
    let averageLatencyMilliseconds: Double
    let p95LatencyMilliseconds: Double
}

// MARK: - Detection

func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Float {
    let overlap = a.intersection(b)
    if overlap.isNull || overlap.isEmpty { return 0 }
    let overlapArea = overlap.width * overlap.height
    let union = a.width * a.height + b.width * b.height - overlapArea
    return union > 0 ? Float(overlapArea / union) : 0
}

// Greedy matching: go through predictions most confident first, each one takes the
// best unmatched ground truth with the same label and IoU >= threshold.
func evaluateDetections(_ cases: [DetectionTestCase], iouThreshold: Float = 0.5) -> DetectionMetrics {
    var tp = 0, fp = 0, fn = 0

    for testCase in cases {
        var unmatched = testCase.expected
        for prediction in testCase.predicted.sorted(by: { $0.confidence > $1.confidence }) {
            let best = unmatched.indices
                .filter { unmatched[$0].label.lowercased() == prediction.label.lowercased() }
                .map { ($0, intersectionOverUnion(unmatched[$0].boundingBox, prediction.boundingBox)) }
                .filter { $0.1 >= iouThreshold }
                .max { $0.1 < $1.1 }

            if let best {
                unmatched.remove(at: best.0)
                tp += 1
            } else {
                fp += 1
            }
        }
        fn += unmatched.count
    }

    // nothing predicted / nothing expected counts as perfect, not 0
    let precision: Float = tp + fp == 0 ? 1 : Float(tp) / Float(tp + fp)
    let recall: Float = tp + fn == 0 ? 1 : Float(tp) / Float(tp + fn)
    return DetectionMetrics(truePositives: tp, falsePositives: fp, falseNegatives: fn, precision: precision, recall: recall)
}

func evaluateDetections(_ testCase: DetectionTestCase, iouThreshold: Float = 0.5) -> DetectionMetrics {
    evaluateDetections([testCase], iouThreshold: iouThreshold)
}

// MARK: - Distance

func evaluateDistances(_ cases: [DistanceTestCase]) -> DistanceMetrics? {
    guard !cases.isEmpty else { return nil }
    let errors = cases.map { abs($0.estimatedMeters - $0.actualMeters) }
    let n = Float(errors.count)
    return DistanceMetrics(
        meanAbsoluteError: errors.reduce(0, +) / n,
        rootMeanSquaredError: (errors.map { $0 * $0 }.reduce(0, +) / n).squareRoot(),
        maxAbsoluteError: errors.max()!
    )
}

// MARK: - Performance

func evaluatePerformance(_ timings: [FrameTiming]) -> PerformanceMetrics? {
    guard !timings.isEmpty else { return nil }

    let times = timings.map(\.timestamp).sorted()
    let span = times.last! - times.first!
    let fps = span > 0 ? Double(times.count - 1) / span : 0

    let latencies = timings.map(\.processingMilliseconds).sorted()
    let average = latencies.reduce(0, +) / Double(latencies.count)
    // nearest-rank p95
    let index = Int((0.95 * Double(latencies.count)).rounded(.up)) - 1
    return PerformanceMetrics(averageFPS: fps, averageLatencyMilliseconds: average, p95LatencyMilliseconds: latencies[index])
}

// Wrap processing calls with this to collect FrameTimings.
struct FrameTimer {
    private(set) var timings: [FrameTiming] = []

    mutating func measure<T>(_ work: () throws -> T) rethrows -> T {
        let start = CACurrentMediaTime() // monotonic, unlike Date
        defer { record(start: start, end: CACurrentMediaTime()) }
        return try work()
    }

    mutating func record(start: TimeInterval, end: TimeInterval) {
        timings.append(FrameTiming(timestamp: start, processingMilliseconds: (end - start) * 1000))
    }
}
