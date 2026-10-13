import CoreGraphics
import Foundation
import Testing

@testable import SceneGeometry

@Suite("T18 - Scene Descriptions")
struct SceneDescriptionBuilderTests {
    
    @Test("Describes a detection and recognized text")
    func describesDetectionAndText() {
        let person = Detection(
            label: "person",
            confidence: 0.95,
            boundingBox: CGRect(
                x: 0.4,
                y: 0.2,
                width: 0.2,
                height: 0.6
            ),
            distance: 2.0,
            bearing: .ahead,
            origin: .model,
            isHazard: false
        )
        
        let roomSign = RecognizedText(
            string: "Room 210",
            confidence: 0.96,
            boundingBox: CGRect(
                x: 0.05,
                y: 0.1,
                width: 0.2,
                height: 0.1
            )
        )
        
        let observation = SceneObservation(
            detections: [person],
            recognizedText: [roomSign]
        )
        
        let description = SceneDescriptionBuilder().describe(observation)
        
        #expect(
            description == "Person 2 metres ahead. Room 210 is visible on your left."
        )
    }
    
    @Test("Places text on the left, ahead, and right")
    func describesTextDiections() {
        let leftText = RecognizedText(
            string: "Left Sign",
            confidence: 0.9,
            boundingBox: CGRect(
                x: 0.05,
                y: 0.1,
                width: 0.1,
                height: 0.1
            )
        )
        
        let centerText = RecognizedText(
            string: "Center Sign",
            confidence: 0.9,
            boundingBox: CGRect(
                x: 0.45,
                y: 0.1,
                width: 0.1,
                height: 0.1
            )
        )
        
        let rightText = RecognizedText(
            string: "Right Sign",
            confidence: 0.9,
            boundingBox: CGRect(
                x: 0.80,
                y: 0.1,
                width: 0.1,
                height: 0.1
            )
        )
        
        let observation = SceneObservation(
            recognizedText: [
                leftText,
                centerText,
                rightText
            ]
        )
        
        let description = SceneDescriptionBuilder()
            .describe(observation)
        
        #expect(
            description ==
            "Left Sign is visible on your left. " +
            "Center Sign is visible ahead. " +
            "Right Sign is visible on your right."
        )
    }
}
