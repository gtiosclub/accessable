import CoreGraphics
import CoreML
import Testing
@testable import SceneGeometry

/// Builds a synthetic (queries, classes)-shaped `MLMultiArray`, or (1, queries, classes)
/// when `batched` — D-FINE's runtime shape has that leading 1 despite its spec not
/// declaring one, and `dfineDetections` is expected to handle both.
private func confidenceArray(_ rows: [[Float]], batched: Bool) throws -> MLMultiArray {
    let queries = rows.count
    let classes = rows.first?.count ?? 0
    let shape: [NSNumber] = batched ? [1, queries, classes] as [NSNumber] : [queries, classes] as [NSNumber]
    let array = try MLMultiArray(shape: shape, dataType: .float32)
    for (row, scores) in rows.enumerated() {
        for (column, score) in scores.enumerated() {
            let index: [NSNumber] = batched
                ? [NSNumber(value: 0), NSNumber(value: row), NSNumber(value: column)]
                : [NSNumber(value: row), NSNumber(value: column)]
            array[index] = NSNumber(value: score)
        }
    }
    return array
}

private func coordinatesArray(_ rows: [[Float]], batched: Bool) throws -> MLMultiArray {
    let queries = rows.count
    let shape: [NSNumber] = batched ? [1, queries, 4] as [NSNumber] : [queries, 4] as [NSNumber]
    let array = try MLMultiArray(shape: shape, dataType: .float32)
    for (row, values) in rows.enumerated() {
        for (column, value) in values.enumerated() {
            let index: [NSNumber] = batched
                ? [NSNumber(value: 0), NSNumber(value: row), NSNumber(value: column)]
                : [NSNumber(value: row), NSNumber(value: column)]
            array[index] = NSNumber(value: value)
        }
    }
    return array
}

/// A tiny two-class vocabulary so tests don't need all 80 COCO labels.
private let testLabels = ["chair", "person"]

@Suite("T31 — decoding D-FINE's raw (no-NMS) output")
struct DFineObjectDetectorTests {
    @Test("picks the highest-scoring class and converts cxcywh to the app's top-left box", arguments: [false, true])
    func decodesOneBox(batched: Bool) throws {
        let confidence = try confidenceArray([[0.9, 0.1]], batched: batched)
        let coordinates = try coordinatesArray([[0.5, 0.4, 0.2, 0.2]], batched: batched)

        let detections = dfineDetections(
            confidence: confidence, coordinates: coordinates,
            minimumConfidence: 0.5, classLabels: testLabels
        )

        let detection = try #require(detections.first)
        #expect(detections.count == 1)
        #expect(detection.label == "chair")
        #expect(abs(detection.confidence - 0.9) < 1e-6)
        // centre (0.5, 0.4), size (0.2, 0.2) -> top-left (0.4, 0.3).
        #expect(abs(detection.boundingBox.minX - 0.4) < 1e-6)
        #expect(abs(detection.boundingBox.minY - 0.3) < 1e-6)
        #expect(abs(detection.boundingBox.width - 0.2) < 1e-6)
    }

    @Test("drops boxes below the confidence floor")
    func filtersLowConfidence() throws {
        let confidence = try confidenceArray([[0.9, 0.1], [0.4, 0.3]], batched: true)
        let coordinates = try coordinatesArray([[0.5, 0.5, 0.1, 0.1], [0.1, 0.1, 0.1, 0.1]], batched: true)

        let detections = dfineDetections(
            confidence: confidence, coordinates: coordinates,
            minimumConfidence: 0.5, classLabels: testLabels
        )
        #expect(detections.count == 1)
    }

    @Test("drops ignored labels, e.g. person (T14 owns those)")
    func filtersIgnoredLabels() throws {
        let confidence = try confidenceArray([[0.1, 0.9]], batched: true)
        let coordinates = try coordinatesArray([[0.5, 0.5, 0.1, 0.1]], batched: true)

        let detections = dfineDetections(
            confidence: confidence, coordinates: coordinates,
            minimumConfidence: 0.5, ignoredLabels: ["person"], classLabels: testLabels
        )
        #expect(detections.isEmpty)
    }

    @Test("suppresses a lower-confidence box of the same label that mostly overlaps a kept one")
    func suppressesOverlappingDuplicate() throws {
        let confidence = try confidenceArray([[0.95, 0], [0.80, 0]], batched: true)
        let coordinates = try coordinatesArray(
            [[0.50, 0.50, 0.30, 0.30], [0.52, 0.50, 0.30, 0.30]], // near-identical boxes
            batched: true
        )

        let detections = dfineDetections(
            confidence: confidence, coordinates: coordinates,
            minimumConfidence: 0.5, classLabels: testLabels
        )
        #expect(detections.count == 1)
        #expect(abs(detections[0].confidence - 0.95) < 1e-6)
    }

    @Test("does not suppress overlapping boxes of different labels")
    func keepsOverlappingDifferentLabels() throws {
        let confidence = try confidenceArray([[0.9, 0], [0, 0.9]], batched: true)
        let coordinates = try coordinatesArray(
            [[0.50, 0.50, 0.30, 0.30], [0.50, 0.50, 0.30, 0.30]], // identical boxes, different labels
            batched: true
        )

        let detections = dfineDetections(
            confidence: confidence, coordinates: coordinates,
            minimumConfidence: 0.5, classLabels: testLabels
        )
        #expect(detections.count == 2)
    }

    @Test("marks only hazard-class labels as hazards, same vocabulary as the old model")
    func marksHazards() throws {
        let confidence = try confidenceArray([[0.9, 0]], batched: true)
        let coordinates = try coordinatesArray([[0.5, 0.5, 0.1, 0.1]], batched: true)

        let detections = dfineDetections(
            confidence: confidence, coordinates: coordinates,
            minimumConfidence: 0.5, classLabels: testLabels
        )
        #expect(try #require(detections.first).isHazard) // "chair" is in hazardLabels
    }
}
