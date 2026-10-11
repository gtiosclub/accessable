import CoreGraphics
import Foundation
import Testing
@testable import SceneGeometry

private func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}

private func prediction(_ label: String, _ rect: CGRect, confidence: Float = 0.9) -> Detection {
    Detection(label: label, confidence: confidence, boundingBox: rect, origin: .model, isHazard: false)
}

@Suite("T20 evaluation")
struct EvaluationTests {
    @Test func iou() {
        #expect(abs(intersectionOverUnion(box(0, 0, 0.2, 0.2), box(0, 0, 0.2, 0.2)) - 1) < 1e-6)
        #expect(intersectionOverUnion(box(0, 0, 0.1, 0.1), box(0.5, 0.5, 0.1, 0.1)) == 0)
        // half overlap: 0.02 / 0.06
        #expect(abs(intersectionOverUnion(box(0, 0, 0.2, 0.2), box(0.1, 0, 0.2, 0.2)) - 1.0 / 3) < 1e-6)
    }

    @Test func perfectMatch() {
        let result = evaluateDetections(DetectionTestCase(
            expected: [GroundTruthDetection(label: "chair", boundingBox: box(0.4, 0.4, 0.2, 0.3))],
            predicted: [prediction("chair", box(0.41, 0.41, 0.2, 0.3))]
        ))
        #expect(result.precision == 1 && result.recall == 1)
    }

    @Test func wrongLabelIsMissAndFalseAlarm() {
        let result = evaluateDetections(DetectionTestCase(
            expected: [GroundTruthDetection(label: "chair", boundingBox: box(0.4, 0.4, 0.2, 0.3))],
            predicted: [prediction("bench", box(0.4, 0.4, 0.2, 0.3))]
        ))
        #expect(result.falsePositives == 1 && result.falseNegatives == 1)
    }

    @Test func duplicateCountsOnce() {
        let result = evaluateDetections(DetectionTestCase(
            expected: [GroundTruthDetection(label: "person", boundingBox: box(0.3, 0.2, 0.2, 0.6))],
            predicted: [prediction("person", box(0.3, 0.2, 0.2, 0.6)), prediction("person", box(0.31, 0.2, 0.2, 0.6), confidence: 0.5)]
        ))
        #expect(result.truePositives == 1 && result.falsePositives == 1)
    }

    @Test func emptyFrameIsPerfect() {
        let result = evaluateDetections(DetectionTestCase(expected: [], predicted: []))
        #expect(result.precision == 1 && result.recall == 1)
    }

    @Test func distanceErrors() throws {
        let result = try #require(evaluateDistances([
            DistanceTestCase(estimatedMeters: 1.1, actualMeters: 1.0),
            DistanceTestCase(estimatedMeters: 1.8, actualMeters: 2.0),
            DistanceTestCase(estimatedMeters: 3.3, actualMeters: 3.0),
        ]))
        #expect(abs(result.meanAbsoluteError - 0.2) < 1e-5)
        #expect(abs(result.rootMeanSquaredError - (0.14 / 3).squareRoot()) < 1e-5)
        #expect(abs(result.maxAbsoluteError - 0.3) < 1e-5)
        #expect(evaluateDistances([]) == nil)
    }

    @Test func performance() throws {
        // 31 frames over 1 second, latency 1...31 ms
        let timings = (0..<31).map { FrameTiming(timestamp: Double($0) / 30, processingMilliseconds: Double($0 + 1)) }
        let result = try #require(evaluatePerformance(timings))
        #expect(abs(result.averageFPS - 30) < 1e-6)
        #expect(result.averageLatencyMilliseconds == 16)
        #expect(result.p95LatencyMilliseconds == 30) // ceil(0.95 * 31) = 30th value
    }

    @Test func frameTimer() {
        var timer = FrameTimer()
        timer.record(start: 1.0, end: 1.015)
        #expect(abs(timer.timings[0].processingMilliseconds - 15) < 1e-6)
    }

    @Test func manifest() throws {
        let json = """
        {"version": 1, "frames": [{"scenario": "chair-ahead", "image": "frames/chair-ahead/0001.jpg",
          "objects": [{"label": "chair", "x": 0.38, "y": 0.42, "width": 0.24, "height": 0.4}]}]}
        """
        let manifest = try JSONDecoder().decode(TestSetManifest.self, from: Data(json.utf8))
        #expect(manifest.frames[0].objects[0].groundTruth.boundingBox == box(0.38, 0.42, 0.24, 0.4))
        #expect(manifest.missingScenarios.count == TestScenario.allCases.count - 1)

        let metrics = evaluateDetector(on: manifest, folder: URL(filePath: "/tmp")) { _ in
            [prediction("chair", box(0.38, 0.42, 0.24, 0.4))]
        }
        #expect(metrics.recall == 1)
    }
}
