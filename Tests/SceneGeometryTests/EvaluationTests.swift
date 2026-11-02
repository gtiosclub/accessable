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

@Suite("T20 — detection and performance evaluation")
struct EvaluationTests {
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

    @Test func performance() throws {
        // 31 frames over 1 second, latency 1...31 ms
        let timings = (0..<31).map { FrameTiming(timestamp: Double($0) / 30, processingMilliseconds: Double($0 + 1)) }
        let result = try #require(evaluatePerformance(timings))
        #expect(abs(result.averageFPS - 30) < 1e-6)
        #expect(result.averageLatencyMilliseconds == 16)
        #expect(result.p95LatencyMilliseconds == 30) // ceil(0.95 * 31) = 30th value
    }

    @Test func frameTimerKeepsTheMostRecentFrames() {
        var timer = FrameTimer(capacity: 3)
        for frame in 0 ..< 5 {
            timer.record(start: Double(frame), end: Double(frame) + 0.015)
        }
        #expect(timer.timings.map(\.timestamp) == [2, 3, 4])
        #expect(abs(timer.timings[0].processingMilliseconds - 15) < 1e-6)
        #expect(timer.metrics?.averageFPS == 1)
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

    @Test("T40 manifest stores environmental conditions")
    func environmentalConditions() throws {
        let json = """
        {
            "version": 1,
            "frames": [
                {
                "scenario": "dim-lighting",
                "image": "frames/dim-lighting/0001.jpg",
                "objects": [],
                "conditions": ["indoor", "dim-lighting", "busy"]
                }
            ]
        }
        """

        let manifest = try JSONDecoder().decode(
            TestSetManifest.self,
            from: Data(json.utf8)
        )

        #expect(
            manifest.frames[0].conditions == [
                .indoor,
                .dimLighting,
                .busy
            ]
        )
    }

    @Test("T40 builds distance cases from measured dataset distances")
    func recordedDistanceCases() throws {
        let json = """
        {
            "version": 1,
            "frames": [
             {
                "scenario": "chair-ahead",
                "image": "frames/chair-ahead/0001.jpg",
                "objects": [
                  {
                    "label": "chair",
                    "x": 0.3,
                    "y": 0.3,
                    "width": 0.3,
                    "height": 0.4
                 }
            ],
            "measuredDistances": {
                "chair": 2.0
            },
            "conditions": ["indoor", "bright-lighting"]
            }
          ]
        }
        """

        let manifest = try JSONDecoder().decode(
            TestSetManifest.self,
            from: Data(json.utf8)
        )

        let cases = distanceTestCases(
            from: manifest,
            folder: URL(filePath: "/tmp")
        ) { _ in
            ["chair": 1.8]
        }

        #expect(cases.count == 1)
        #expect(cases[0].estimatedMeters == 1.8)
        #expect(cases[0].actualMeters == 2.0)
    }

    @Test("T40 evaluates distance error from recorded frames")
    func recordedDistanceMetrics() throws {
        let json = """
        {
            "version": 1,
            "frames": [
               {
                "scenario": "chair-ahead",
                "image": "frames/chair-ahead/0001.jpg",
                "objects": [],
                "measuredDistances": {
                    "chair": 2.0
                }
            }
          ]
        }
        """

        let manifest = try JSONDecoder().decode(
            TestSetManifest.self,
            from: Data(json.utf8)
        )

        let metrics = try #require(
            evaluateDistanceEstimates(
                on: manifest,
                folder: URL(filePath: "/tmp")
            ) { _ in
                ["chair": 1.8]
            }
        )

        #expect(abs(metrics.meanAbsoluteError - 0.2) < 0.0001)
        #expect(abs(metrics.rootMeanSquaredError - 0.2) < 0.001)
        #expect(abs(metrics.meanBias + 0.2) < 0.0001)
        #expect(metrics.sampleCount == 1)
    }

}
