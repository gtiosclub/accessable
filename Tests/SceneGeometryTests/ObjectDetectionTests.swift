import CoreGraphics
import Testing
@testable import SceneGeometry

private struct FakeObservation: RecognizedObjectObservation {
    var boundingBox = CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
    var confidence: Float = 0.9
    var topLabel: String? = "chair"
}

@Suite("T13 object detection")
struct ObjectDetectionTests {
    @Test func flipsYAxis() throws {
        let obs = FakeObservation(boundingBox: CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.3))
        let detection = try #require(objectDetections(from: [obs]).first)
        // y 0.1...0.4 from the bottom is 0.6...0.9 from the top
        #expect(abs(detection.boundingBox.minY - 0.6) < 1e-6)
        #expect(abs(detection.boundingBox.minX - 0.2) < 1e-6)
    }

    @Test func filtersLowConfidence() {
        let results = objectDetections(from: [FakeObservation(confidence: 0.3), FakeObservation(confidence: 0.5)])
        #expect(results.count == 1)
    }

    @Test func skipsMissingLabels() {
        #expect(objectDetections(from: [FakeObservation(topLabel: nil)]).isEmpty)
    }

    @Test func sortsByConfidence() {
        let results = objectDetections(from: [FakeObservation(confidence: 0.5), FakeObservation(confidence: 0.9)])
        #expect(results.map(\.confidence) == [0.9, 0.5])
    }

    @Test func marksHazards() {
        let results = objectDetections(from: [FakeObservation(topLabel: "chair"), FakeObservation(topLabel: "person")])
        #expect(results.first { $0.label == "chair" }?.isHazard == true)
        #expect(results.first { $0.label == "person" }?.isHazard == false)
    }
}
