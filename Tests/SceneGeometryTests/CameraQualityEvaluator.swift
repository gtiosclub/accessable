import Testing
@testable import SceneGeometry

@Suite("T32 - Camera Quality Feedback")
struct CameraQualityEvaluatorTest {
    private let evaluator = CameraQualityEvaluator(
        minimumAmbientIntensity: 250,
        minimumSharpnessScore: 4,
        maximumVerticalComponent: 0.35
    )
    
    @Test("Dark image asks for more light")
    func darkImage() {
        let input = CameraQualityInput(
            forwardY: 0,
            ambientIntensity: 100,
            sharpnessScore: 10,
            isMovingTooFast: false
        )
        
        #expect(evaluator.evaluate(input) == .tooDark)
    }
    
    @Test("Fast movement asks the user to hold steady")
    func excessiveMotion() {
        let input = CameraQualityInput(
            forwardY: 0,
            ambientIntensity: 1000,
            sharpnessScore: 10,
            isMovingTooFast: true
        )
        
        #expect(evaluator.evaluate(input) == .holdSteady)
    }
    
    @Test("Blurry image asks the user to hold steady")
    func blurryImage() {
        let input = CameraQualityInput(
            forwardY: 0,
            ambientIntensity: 1000,
            sharpnessScore: 2,
            isMovingTooFast: false
        )
        
        #expect(evaluator.evaluate(input) == .holdSteady)
    }
    
    @Test("Camera pointing down asks the user to tilt up")
    func cameraTooLow() {
        let input = CameraQualityInput(
            forwardY: -0.6,
            ambientIntensity: 1000,
            sharpnessScore: 10,
            isMovingTooFast: false
        )
        
        #expect(evaluator.evaluate(input) == .tiltUp)
    }
    
    @Test("Camera pointing up asks the user to tilt down")
    func cameraTooHigh() {
        let input = CameraQualityInput(
            forwardY: 0.6,
            ambientIntensity: 1000,
            sharpnessScore: 10,
            isMovingTooFast: false
        )
        
        #expect(evaluator.evaluate(input) == .tiltDown)
    }
    
    @Test("Good camera position returns no feedback")
    func goodFrame() {
        let input = CameraQualityInput(
            forwardY: 0,
            ambientIntensity: 1000,
            sharpnessScore: 10,
            isMovingTooFast: false
        )
        
        #expect(evaluator.evaluate(input) == nil)
    }
}
