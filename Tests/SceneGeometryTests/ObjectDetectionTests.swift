import CoreGraphics
import Testing
@testable import SceneGeometry

private struct FakeObservation: RecognizedObjectObservation {
    var boundingBox = CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
    var confidence: Float = 0.9
    var topLabel: String? = "chair"
}

@Suite("T13 — object detection results")
struct ObjectDetectionTests {
    @Test("flips Vision's bottom-left origin to top-left")
    func flipsYAxis() throws {
        let observation = FakeObservation(boundingBox: CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.3))
        let detection = try #require(objectDetections(from: [observation], minimumConfidence: 0.5).first)
        // y 0.1...0.4 from the bottom is 0.6...0.9 from the top.
        #expect(abs(detection.boundingBox.minY - 0.6) < 1e-6)
        #expect(abs(detection.boundingBox.minX - 0.2) < 1e-6)
    }

    @Test("drops low confidence, missing labels and ignored labels")
    func filters() {
        let results = objectDetections(
            from: [
                FakeObservation(confidence: 0.3),
                FakeObservation(confidence: 0.6),
                FakeObservation(topLabel: nil),
                FakeObservation(topLabel: "person"),
            ],
            minimumConfidence: 0.5,
            ignoredLabels: ["person"]
        )
        #expect(results.map(\.label) == ["chair"])
    }

    @Test("sorts by confidence and marks only walkable-into classes as hazards")
    func sortsAndMarksHazards() {
        let results = objectDetections(
            from: [FakeObservation(confidence: 0.6, topLabel: "Cup"), FakeObservation(confidence: 0.9, topLabel: "Chair")],
            minimumConfidence: 0.5
        )
        #expect(results.map(\.label) == ["chair", "cup"])
        #expect(results.map(\.isHazard) == [true, false])
    }
}

@Suite("Fusing recognized objects with geometric obstacles")
struct DetectionFusionTests {
    private func obstacle(_ box: CGRect, distance: Double = 2) -> Detection {
        Detection(label: "obstacle", confidence: 1, boundingBox: box, distance: distance, origin: .geometric, isHazard: true)
    }

    private func object(_ label: String, _ box: CGRect, distance: Double? = 2.4) -> Detection {
        Detection(label: label, confidence: 0.8, boundingBox: box, distance: distance, origin: .model, isHazard: true)
    }

    @Test("an obstacle under a recognized chair becomes the chair, once")
    func labelsObstacle() throws {
        let fused = fuse(
            obstacles: [obstacle(CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.3))],
            recognized: [object("chair", CGRect(x: 0.35, y: 0.4, width: 0.3, height: 0.45))]
        )

        #expect(fused.count == 1)
        let chair = try #require(fused.first)
        #expect(chair.label == "chair")
        #expect(chair.origin == .geometric)
        #expect(chair.distance == 2)
    }

    @Test("objects elsewhere in the frame are kept separately")
    func keepsUnmatched() {
        let fused = fuse(
            obstacles: [obstacle(CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.3))],
            recognized: [object("bench", CGRect(x: 0, y: 0, width: 0.1, height: 0.1))]
        )
        #expect(fused.map(\.label) == ["obstacle", "bench"])
    }

    @Test("a person seen past a chair does not become the chair")
    func smallBoxInsideLargeBoxIsNotFused() {
        // The chair's projected box is big; the far person's box lands inside it.
        let fused = fuse(
            obstacles: [obstacle(CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.6), distance: 1.5)],
            recognized: [object("person", CGRect(x: 0.45, y: 0.25, width: 0.08, height: 0.15), distance: 1.6)]
        )
        #expect(fused.map(\.label) == ["obstacle", "person"])
    }

    @Test("boxes that overlap at different depths are different things")
    func distanceMismatchIsNotFused() {
        let fused = fuse(
            obstacles: [obstacle(CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.3), distance: 1.5)],
            recognized: [object("person", CGRect(x: 0.35, y: 0.4, width: 0.3, height: 0.45), distance: 3.4)]
        )
        #expect(fused.map(\.label) == ["obstacle", "person"])
    }

    @Test("only things one can walk into lend their label")
    func onlyFusableLabels() {
        let fused = fuse(
            obstacles: [obstacle(CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.3))],
            recognized: [object("cell phone", CGRect(x: 0.35, y: 0.4, width: 0.3, height: 0.45))]
        )
        #expect(fused.map(\.label) == ["obstacle", "cell phone"])
    }

    @Test("each recognized object labels at most one obstacle")
    func oneToOne() {
        let fused = fuse(
            obstacles: [
                obstacle(CGRect(x: 0.40, y: 0.5, width: 0.10, height: 0.3)),
                obstacle(CGRect(x: 0.52, y: 0.5, width: 0.10, height: 0.3)),
            ],
            recognized: [object("chair", CGRect(x: 0.38, y: 0.45, width: 0.14, height: 0.4))]
        )
        #expect(fused.map(\.label) == ["chair", "obstacle"])
    }
}

@Suite("Rectangle overlap")
struct RectOverlapTests {
    @Test("IoU of identical, disjoint and half-overlapping boxes")
    func intersectionOverUnion() {
        let a = CGRect(x: 0, y: 0, width: 1, height: 1)
        #expect(a.intersectionOverUnion(with: a) == 1)
        #expect(a.intersectionOverUnion(with: CGRect(x: 2, y: 2, width: 1, height: 1)) == 0)
        #expect(abs(a.intersectionOverUnion(with: CGRect(x: 0.5, y: 0, width: 1, height: 1)) - 1.0 / 3.0) < 1e-9)
    }

    @Test("overlap of the smaller box is 1 when one contains the other")
    func overlapOfSmaller() {
        let big = CGRect(x: 0, y: 0, width: 1, height: 1)
        let small = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        #expect(abs(big.overlapOfSmaller(with: small) - 1) < 1e-9)
        #expect(big.intersectionOverUnion(with: small) < 0.02)
    }
}
