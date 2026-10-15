import CoreGraphics
import Testing
@testable import SceneGeometry

@Suite("T18 — instant scene descriptions")
struct SceneDescriptionBuilderTests {
    private func sign(_ string: String, x: CGFloat) -> RecognizedText {
        RecognizedText(string: string, confidence: 0.9, boundingBox: CGRect(x: x, y: 0.1, width: 0.1, height: 0.1))
    }

    private func object(_ label: String, distance: Double, isHazard: Bool = true) -> Detection {
        Detection(
            label: label, confidence: 0.9, boundingBox: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.6),
            distance: distance, bearing: .ahead, origin: .model, isHazard: isHazard
        )
    }

    @Test("describes a detection and recognized text")
    func detectionAndText() {
        let observation = SceneObservation(
            detections: [object("person", distance: 2, isHazard: false)],
            recognizedText: [sign("Room 210", x: 0.05)]
        )
        #expect(SceneDescriptionBuilder().describe(observation) == "Person 2 metres ahead. Room 210 is visible on your left.")
    }

    @Test("places text on the left, ahead and right")
    func textDirections() {
        let observation = SceneObservation(recognizedText: [sign("Left", x: 0.1), sign("Centre", x: 0.45), sign("Right", x: 0.8)])
        #expect(SceneDescriptionBuilder().describe(observation)
            == "Left is visible on your left. Centre is visible ahead. Right is visible on your right.")
    }

    @Test("surface hazards come first and the list is capped")
    func prioritizesAndCaps() {
        let observation = SceneObservation(
            detections: [object("bench", distance: 3), object("chair", distance: 1), object("cup", distance: 0.5, isHazard: false)],
            recognizedText: [sign("Exit", x: 0.5)],
            elevationHazards: [ElevationHazard(type: .stepDown, distance: 2, heightChange: -0.15)]
        )
        #expect(SceneDescriptionBuilder().describe(observation)
            == "Step down 2 metres ahead. Chair 1 metre ahead. Bench 3 metres ahead. Cup 0.5 metres ahead.")
    }

    @Test("an empty scene still gets a sentence")
    func emptyScene() {
        #expect(SceneDescriptionBuilder().describe(.empty) == "Nothing detected nearby.")
    }
}
