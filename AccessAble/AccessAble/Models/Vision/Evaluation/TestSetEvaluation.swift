import CoreGraphics
import Foundation
import ImageIO

// T20: one run over the whole recorded test set — precision and recall overall, per
// scenario and per lighting, distance error where tape measurements exist, and how long
// detection took per frame.

struct TestSetReport: Sendable {
    let frameCount: Int
    let overall: DetectionMetrics
    let byScenario: [TestScenario: DetectionMetrics]
    /// Only frames whose `conditions` give a lighting.
    let byLighting: [FrameConditions.Lighting: DetectionMetrics]
    /// nil when no frame has both a measured and an estimated distance.
    let distance: DistanceMetrics?
    /// Timed on whatever ran the evaluation, so only comparable between runs on one machine.
    let performance: PerformanceMetrics?
    let missingScenarios: [TestScenario]

    /// A plain-text table for the test log.
    var summary: String {
        var lines = ["Test set: \(frameCount) frames, \(TestScenario.allCases.count - missingScenarios.count) of \(TestScenario.allCases.count) scenarios"]
        lines.append(Self.row("overall", overall))
        for scenario in TestScenario.allCases {
            if let metrics = byScenario[scenario] { lines.append(Self.row(scenario.rawValue, metrics)) }
        }
        for lighting in FrameConditions.Lighting.allCases {
            if let metrics = byLighting[lighting] { lines.append(Self.row("lighting \(lighting.rawValue)", metrics)) }
        }
        if let distance {
            lines.append(String(
                format: "distance: MAE %.2f m, RMSE %.2f m, max %.2f m, bias %+.2f m (%d measured)",
                distance.meanAbsoluteError, distance.rootMeanSquaredError, distance.maxAbsoluteError,
                distance.meanBias, distance.sampleCount
            ))
        } else {
            lines.append("distance: no frames with both a measured and an estimated distance")
        }
        if let performance {
            lines.append(String(
                format: "detection time on this machine: %.1f ms average, %.1f ms p95",
                performance.averageLatencyMilliseconds, performance.p95LatencyMilliseconds
            ))
        }
        if !missingScenarios.isEmpty {
            lines.append("not recorded yet: \(missingScenarios.map(\.rawValue).joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func row(_ name: String, _ metrics: DetectionMetrics) -> String {
        let padded = name.padding(toLength: 24, withPad: " ", startingAt: 0)
        return String(
            format: "%@ precision %.2f  recall %.2f  (TP %d, FP %d, FN %d)",
            padded, metrics.precision, metrics.recall,
            metrics.truePositives, metrics.falsePositives, metrics.falseNegatives
        )
    }
}

/// Runs `detect` on every frame of the test set and scores it. `labels` limits scoring
/// to the classes being evaluated, as in `evaluateDetector`.
///
/// A frame's distance is scored per measured label: the distance recorded with the frame
/// if there is one, otherwise the most confident prediction with that label that has a
/// distance.
func evaluateTestSet(
    _ manifest: TestSetManifest,
    folder: URL,
    labels: Set<String>? = nil,
    detect: (URL) throws -> [Detection]
) rethrows -> TestSetReport {
    let clock = ContinuousClock()
    let started = clock.now
    var timings: [FrameTiming] = []
    var cases: [(frame: AnnotatedFrame, testCase: DetectionTestCase)] = []
    var distances: [DistanceTestCase] = []

    for frame in manifest.frames {
        let start = clock.now
        let predicted = try detect(folder.appending(path: frame.image))
        timings.append(FrameTiming(timestamp: seconds(start - started), processingMilliseconds: seconds(clock.now - start) * 1000))

        let keep = { (label: String) in labels?.contains(label) ?? true }
        cases.append((frame, DetectionTestCase(
            expected: frame.objects.map(\.groundTruth).filter { keep($0.label) },
            predicted: predicted.filter { keep($0.label) }
        )))

        for (label, actual) in frame.measuredDistances ?? [:] where keep(label) {
            let estimate = frame.estimatedDistances?[label] ?? predicted
                .filter { $0.label.lowercased() == label.lowercased() && $0.distance != nil }
                .max { $0.confidence < $1.confidence }
                .flatMap { $0.distance.map(Float.init) }
            if let estimate {
                distances.append(DistanceTestCase(estimatedMeters: estimate, actualMeters: actual))
            }
        }
    }

    return TestSetReport(
        frameCount: manifest.frames.count,
        overall: evaluateDetections(cases.map(\.testCase)),
        byScenario: Dictionary(grouping: cases, by: \.frame.scenario).mapValues { evaluateDetections($0.map(\.testCase)) },
        byLighting: Dictionary(grouping: cases.filter { $0.frame.conditions?.lighting != nil }) { $0.frame.conditions!.lighting! }
            .mapValues { evaluateDetections($0.map(\.testCase)) },
        distance: evaluateDistances(distances),
        performance: evaluatePerformance(timings),
        missingScenarios: manifest.missingScenarios
    )
}

private func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

enum TestImageError: Error, Equatable {
    case unreadable(URL)
}

/// Loads a test-set image with the orientation its EXIF data records. Phone photos are
/// usually stored sideways with an orientation tag; annotations are upright, so the
/// orientation must be passed on to Vision for the boxes to line up.
func loadTestImage(at url: URL) throws -> (image: CGImage, orientation: CGImagePropertyOrientation) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw TestImageError.unreadable(url) }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let raw = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
    return (image, CGImagePropertyOrientation(rawValue: raw) ?? .up)
}
