import CoreGraphics
import Testing
@testable import SceneGeometry

@Suite("T43 - Point and Identify")
struct PointIdentifierTests {
    private let identifier = PointIdentifier()
    
    @Test("Text near the center is preferred over an object")
    func textIsPreferred() {
        let observation = SceneObservation(
            detections: [
                Detection(
                    label: "door",
                    confidence: 0.9,
                    boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                    origin: .model,
                    isHazard: false
                )
            ],
            recognizedText: [
                RecognizedText(
                    string: "Room 204",
                    confidence: 0.95,
                    boundingBox: CGRect(x: 0.43, y: 0.45, width: 0.14, height: 0.1)
                )
            ]
        )
        
        #expect(
            identifier.identify(in: observation) == PointIdentification(text: "Room 204", kind: .text)
        )
    }
    
    @Test("Object is returned when there is no text")
    func objectFallback() {
        let observation = SceneObservation(
            detections: [
                Detection(
                    label: "chair",
                    confidence: 0.88,
                    boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                    origin: .model,
                    isHazard: true
                )
            ]
        )
        
        #expect(
            identifier.identify(in: observation) == PointIdentification(text: "chair", kind: .object)
        )
    }
    
    @Test("Detection far from the center is ignored")
    func offCenterIsIngored() {
        let observation = SceneObservation(
            detections: [
                Detection(
                    label: "chair",
                    confidence: 0.95,
                    boundingBox: CGRect(x: 0.02, y: 0.02, width: 0.1, height: 0.1),
                    origin: .model,
                    isHazard: true
                )
            ]
        )
        
        #expect(identifier.identify(in: observation) == nil)
    }
    
    @Test("Closer object wins")
    func closerObjectWins() {
        let observation = SceneObservation(
            detections: [
                Detection(
                    label: "table",
                    confidence: 0.95,
                    boundingBox: CGRect(x: 0.25, y: 0.4, width: 0.1, height: 0.1),
                    origin: .model,
                    isHazard: false
                ),
                Detection(
                    label: "chair",
                    confidence: 0.8,
                    boundingBox: CGRect(x: 0.46, y: 0.46, width: 0.08, height: 0.08),
                    origin: .model,
                    isHazard: true
                )
            ]
        )
        
        #expect(
            identifier.identify(in: observation) == PointIdentification(text: "chair", kind: .object)
        )
    }
    
    @Test("Empty scene returns nothing")
    func emptyScene() {
        #expect(identifier.identify(in: .empty) == nil)
    }
}
