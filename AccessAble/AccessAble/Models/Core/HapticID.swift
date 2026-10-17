import Foundation

/// Haptic vocabulary v1. Each case maps to an AHAP file of the same name (e.g. `turnLeft.ahap`)
/// owned by the Haptics subteam (3.2).
enum HapticID: String, Codable, CaseIterable, Sendable {
    case obstacleNear
    case obstacleNearer
    case stop
    case turnLeft
    case turnRight
    case onRouteHeartbeat
    case arrived
    case attention
    case error

    var ahapFileName: String { rawValue }

    var ahapURL: URL? {
        Bundle.main.url(forResource: ahapFileName, withExtension: "ahap")
    }
    
    var loopPeriod: TimeInterval? {
        switch self {
        case .obstacleNear: 1.2
        case .obstacleNearer: 0.7
        case .stop: 1.0
        default: nil
        }
    }

    /// Spoken/visible name used in the Practice screen and Settings.
    var displayName: String {
        switch self {
        case .obstacleNear: "Obstacle near"
        case .obstacleNearer: "Obstacle nearer"
        case .stop: "Stop"
        case .turnLeft: "Turn left"
        case .turnRight: "Turn right"
        case .onRouteHeartbeat: "On route"
        case .arrived: "Arrived"
        case .attention: "Attention"
        case .error: "Error"
        }
    }

    /// Describes how the pattern feels, for the Practice screen.
    var patternDescription: String {
        switch self {
        case .obstacleNear: "One soft buzz, repeating slowly"
        case .obstacleNearer: "Two stronger buzzes, repeating quickly"
        case .stop: "A hard, almost constant buzz"
        case .turnLeft: "Two short, sharp buzzes"
        case .turnRight: "One long, sharp buzz"
        case .onRouteHeartbeat: "A gentle double tap every few seconds"
        case .arrived: "Three buzzes getting stronger, then a long buzz that fades"
        case .attention: "One sharp tap"
        case .error: "Three dull buzzes getting weaker"
        }
    }
}
