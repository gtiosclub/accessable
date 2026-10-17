import CoreGraphics
import Foundation
import Testing
@testable import SceneGeometry

@Suite("T14 — people detection conversion")
struct PeopleDetectionTests {
    @Test("flips Vision's bottom-left origin to the app's top-left origin")
    func yAxisFlip() throws {
        // A person in the lower-middle of the frame, as Vision reports it.
        let observation = StubHumanObservation(
            boundingBox: CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.3),
            confidence: 0.94
        )

        let detection = try #require(personDetections(from: [observation]).first)

        #expect(abs(detection.boundingBox.minX - 0.2) < 1e-6)
        #expect(abs(detection.boundingBox.width - 0.3) < 1e-6)
        // Vision's box spans y 0.1...0.4 from the bottom, which is 0.6...0.9 from the top.
        #expect(abs(detection.boundingBox.minY - 0.6) < 1e-6)
        #expect(abs(detection.boundingBox.height - 0.3) < 1e-6)
    }

    @Test("a box reaching the top of the frame lands at the top of the flipped box")
    func flipIsSelfConsistent() throws {
        let observation = StubHumanObservation(
            boundingBox: CGRect(x: 0, y: 0.7, width: 1, height: 0.3),
            confidence: 0.8
        )

        let detection = try #require(personDetections(from: [observation]).first)

        #expect(abs(detection.boundingBox.minY) < 1e-6)
        #expect(abs(detection.boundingBox.maxY - 0.3) < 1e-6)
    }

    @Test("clamps a person who is partly out of shot")
    func clampsOutOfFrameBoxes() throws {
        let observation = StubHumanObservation(
            boundingBox: CGRect(x: -0.1, y: -0.2, width: 0.5, height: 0.6),
            confidence: 0.7
        )

        let box = try #require(personDetections(from: [observation]).first).boundingBox

        #expect(box.minX >= 0)
        #expect(box.minY >= 0)
        #expect(box.maxX <= 1 + 1e-6)
        #expect(box.maxY <= 1 + 1e-6)
        #expect(abs(box.width - 0.4) < 1e-6)
    }

    @Test("filters on confidence, inclusive of the threshold")
    func confidenceFiltering() {
        let observations: [any HumanRectangleObservation] = [
            StubHumanObservation(boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1), confidence: 0.49),
            StubHumanObservation(boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1), confidence: 0.50),
            StubHumanObservation(boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1), confidence: 0.94),
        ]

        #expect(personDetections(from: observations, minimumConfidence: 0.5).count == 2)
        #expect(personDetections(from: observations, minimumConfidence: 0).count == 3)
        #expect(personDetections(from: observations, minimumConfidence: 0.95).isEmpty)
    }

    @Test("most confident first")
    func sortedByConfidence() {
        let observations: [any HumanRectangleObservation] = [
            StubHumanObservation(boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1), confidence: 0.6),
            StubHumanObservation(boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1), confidence: 0.94),
            StubHumanObservation(boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1), confidence: 0.75),
        ]

        let confidences = personDetections(from: observations).map(\.confidence)
        #expect(confidences == [0.94, 0.75, 0.6])
    }

    @Test("fills in the shared Detection contract correctly")
    func detectionFields() throws {
        let observation = StubHumanObservation(
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.5),
            confidence: 0.9
        )

        let detection = try #require(personDetections(from: [observation]).first)

        #expect(detection.label == "person")
        #expect(detection.origin == .model)
        // A person is a moving collision risk, handled by the corridor logic — not
        // something you fall off, which is what `isHazard` means in this codebase.
        #expect(detection.isHazard == false)
        // Depth is a different module's job.
        #expect(detection.distance == nil)
        #expect(detection.bearing == nil)
        #expect(detection.trackID == nil)
    }

    @Test("an empty frame is not an error")
    func noObservations() {
        #expect(personDetections(from: []).isEmpty)
    }

    /// Exercises the real Vision request end to end on a generated image — the task
    /// sheet's "test against saved images" path. Proves the plumbing runs and that a
    /// frame with nobody in it comes back empty rather than throwing. Detection quality
    /// itself is Apple's to guarantee, not ours to assert.
    @Test("the still-image path runs and finds nobody in a blank frame")
    func stillImageDetection() throws {
        let width = 128
        let height = 128
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        #expect(try PeopleDetector().detect(cgImage: image).isEmpty)
    }
}
