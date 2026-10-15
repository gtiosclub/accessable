import Foundation
import Testing

@testable import SceneGeometry

@Suite("T16 - Obstacle Alert Thresholds")
struct ObstacleAlertEvaluatorTests {
    @Test("Same object keeps the same ID across frames")
    func sameObjectAcrossFrames() {
        
        // Create the evaluator we want to test
        var evaluator = ObstacleAlertEvaluator()
        
        // Use one ID for the same obstacle across multiple frames
        let objectID = UUID()
        
        // First frame: the obstacle is 2.9 meters away
        let firstInput = ObstacleAlertInput(
            objectID: objectID,
            distance: 2.9,
            direction: 0,
            intersectsWalkingCorridor: true,
            timestamp: 1
        )
        
        // Second frame: the same obstacle moved closer to 1.9 meters
        let secondInput = ObstacleAlertInput(
            objectID: objectID,
            distance: 1.9,
            direction: 0,
            intersectsWalkingCorridor: true,
            timestamp: 2
        )
        
        // Run both frames through the alert evaluator
        let firstAlert = evaluator.evaluate(firstInput)
        let secondAlert = evaluator.evaluate(secondInput)
        
        // At 2.9 meters, the obstacle should first be announced
        #expect(firstAlert?.type == .newObstacle)
        
        // At 1.9 meters, the same obstacle should become a warning
        #expect(secondAlert?.type == .warning)
    }
    
    @Test("Alerts only when crossing a new distance threshold")
    func alertsOnlyOnThresholdCrossings() {
        var evaluator = ObstacleAlertEvaluator()
        let objectID = UUID()
        
        let outsideAlert = evaluator.evaluate(
            ObstacleAlertInput(
                objectID: objectID,
                distance: 3.2,
                direction: 0,
                intersectsWalkingCorridor: false,
                timestamp: 0
            )
        )
        
        #expect(outsideAlert == nil)
        
        // Enters the corridor within 3 meters -> new obstacle
        let newObstacleAlert = evaluator.evaluate(
            ObstacleAlertInput(
                objectID: objectID,
                distance: 2.9,
                direction: 0,
                intersectsWalkingCorridor: true,
                timestamp: 1
            )
        )
        
        #expect(newObstacleAlert?.type == .newObstacle)
        
        // Still in the same 3 meter threshold -> no repeated alert
        let repeatedThreeMeterAlert = evaluator.evaluate(
            ObstacleAlertInput(
                objectID: objectID,
                distance: 2.7,
                direction: 0,
                intersectsWalkingCorridor: true,
                timestamp: 2
            )
        )
        
        #expect(repeatedThreeMeterAlert == nil)
        
        // Crosses into the 2 meter threshold -> warning
        let warningAlert = evaluator.evaluate(
            ObstacleAlertInput(
                objectID: objectID,
                distance: 1.9,
                direction: 0,
                intersectsWalkingCorridor: true,
                timestamp: 3
            )
        )
        
        #expect(warningAlert?.type == .warning)
        
        // Still in the same 2 meter threshold -> no repeated alert
        let repeatedWarningAlert = evaluator.evaluate(
            ObstacleAlertInput(
                objectID: objectID,
                distance: 1.8,
                direction: 0,
                intersectsWalkingCorridor: true,
                timestamp: 4
            )
        )
        
        #expect(repeatedWarningAlert == nil)
        
        // Crosses into the 1 meter threshold -> urgent
        let urgentAlert = evaluator.evaluate(
            ObstacleAlertInput(
                objectID: objectID,
                distance: 0.9,
                direction: 0,
                intersectsWalkingCorridor: true,
                timestamp: 5
            )
        )
        
        #expect(urgentAlert?.type == .urgent)
    }
}

