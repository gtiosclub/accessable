import Foundation

/// Haptic vocabulary v1. Each case maps to an AHAP file of the same name (e.g. `turnLeft.ahap`)
/// owned by the Haptics subteam (3.2).
///
/// The iPhone has a single actuator, so direction is encoded as a pattern, not a location:
/// turn left = 2 pulses, turn right = 3 pulses.
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
        case .obstacleNear: "Slow, soft pulses"
        case .obstacleNearer: "Faster, stronger pulses"
        case .stop: "One long, strong buzz"
        case .turnLeft: "Two short pulses"
        case .turnRight: "Three short pulses"
        case .onRouteHeartbeat: "A gentle double tap every few seconds"
        case .arrived: "Rising pattern"
        case .attention: "One sharp tap"
        case .error: "Three quick buzzes"
        }
    }
}
