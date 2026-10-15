import Foundation

// Information we need about an obstacle for each frame
struct ObstacleAlertInput: Sendable {
    let objectID: UUID
    let distance: Float
    let direction: Float
    let intersectsWalkingCorridor: Bool
    let timestamp: TimeInterval
}

// THe different levels of alerts we can send
enum ObstacleAlertType: Equatable, Sendable {
    case newObstacle
    case warning
    case urgent
}

// The alert that gets returned when an obstacle needs a new warning
struct ObstacleAlert: Sendable {
    let objectID: UUID
    let type: ObstacleAlertType
    let distance: Float
    let direction: Float
}

// Keeps track of what we already announched for each obstacle
struct AlertState: Sendable {
    var hasEnteredCorridor: Bool
    var lastThreshold: Int?
    var lastAlertTime: TimeInterval?
}

struct ObstacleAlertEvaluator: Sendable {
    // Stores the current alert state for every tracked obstacle
    private var alertStates: [UUID: AlertState] = [:]
    
    // Checks one obstacle and returns an alert only when needed
    mutating func evaluate(_ input: ObstacleAlertInput) -> ObstacleAlert? {
        
        // Get the obstacle's previous state or create a new one
        var state = alertStates[input.objectID] ?? AlertState(hasEnteredCorridor: false, lastThreshold: nil, lastAlertTime: nil)
        
        // If the obstacle is outside the walking path, do not alert
        // Reset its state so it can alert again if it re-enters later
        if !input.intersectsWalkingCorridor {
            state.hasEnteredCorridor = false
            state.lastThreshold = nil
            state.lastAlertTime = nil
            
            alertStates[input.objectID] = state
            return nil
        }
        
        // Mark that this obstacle is now inside the walking corridor
        if !state.hasEnteredCorridor {
            state.hasEnteredCorridor = true
        }
        
        // Figure out which distance threshold the obstacle is currently in
        let currentThreshold: Int?
        
        if input.distance <= 1.0 {
            currentThreshold = 1
        } else if input.distance <= 2.0 {
            currentThreshold = 2
        } else if input.distance <= 3.0 {
            currentThreshold = 3
        } else {
            currentThreshold = nil
        }
        
        // If it is farther than 3 meters away, no alert is needed
        guard let currentThreshold else {
            alertStates[input.objectID] = state
            return nil
        }
        
        // If we already warned about this threshold or something more urgent, do not repeat the same alert again
        if let lastThreshold = state.lastThreshold,
           currentThreshold >= lastThreshold {
            alertStates[input.objectID] = state
            return nil
        }
        
        // Choose the alert type based on the distance threshold
        let alertType: ObstacleAlertType
        
        switch currentThreshold {
        case 3:
            alertType = .newObstacle
        case 2:
            alertType = .warning
        case 1:
            alertType = .urgent
        default:
            alertStates[input.objectID] = state
            return nil
        }
        
        // Save the new threshold so we do not announce it next frame
        state.lastThreshold = currentThreshold
        state.lastAlertTime = input.timestamp
        alertStates[input.objectID] = state
        
        // Return the alert for the rest of the app to use
        return ObstacleAlert(objectID: input.objectID, type: alertType, distance: input.distance, direction: input.direction)
    }
}
