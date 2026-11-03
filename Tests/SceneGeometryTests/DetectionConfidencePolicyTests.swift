import Testing
@testable import SceneGeometry

@Suite("T39 - Detection Confidence Thresholds")
struct DetectionConfidencePolicyTests {
    
    @Test("Uses the default threshold for an unconfigured class")
    func defualtThreshold() {
        let policy = DetectionConfidencePolicy(
            defaultThreshold: 0.5
        )
        
        #expect(
            policy.accepts(
                label: "chair",
                confidence: 0.49
            ) == false
        )
        
        #expect (
            policy.accepts(
                label: "chair",
                confidence: 0.50
            ) == true
        )
    }
    
    @Test("Uses a class-specific threshold")
    func classSpecificThreshold() {
        let policy = DetectionConfidencePolicy(
            defaultThreshold: 0.5,
            thresholdsByLabel: [
                "chair": 0.35
            ]
        )
        
        #expect(
            policy.accepts(
                label: "chair",
                confidence: 0.40
            )
        )
        
        #expect(
            policy.accepts(
                label: "table",
                confidence: 0.40
            ) == false
        )
    }
    
    @Test("Label matching is case insensitive")
    func caseInsensitiveLabels() {
        let policy = DetectionConfidencePolicy(
            thresholdsByLabel: [
                "chair": 0.6
            ]
        )
        
        #expect(
            policy.threshold(for: "CHAIR") == 0.6
        )
        
        #expect(
            policy.threshold(for: "Chair") == 0.6
        )
    }
    
    @Test("A detection exactly at the threshold is accepted")
    func inclusiveThreshold() {
        let policy = DetectionConfidencePolicy(
            thresholdsByLabel: [
                "chair": 0.65
            ]
        )
        
        #expect(
            policy.accepts(
                label: "chair",
                confidence: 0.65
            )
        )
    }
}
