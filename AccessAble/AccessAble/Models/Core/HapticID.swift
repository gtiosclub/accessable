import Foundation

/// Haptic vocabulary v1, owned by the Haptics subteam (3.2). Most cases map to an AHAP file of
/// the same name (e.g. `stop.ahap`); those with a `systemHaptic` play that system haptic
/// instead, as the interaction spec asks (e.g. Destination Reached → Success).
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
    /// Walking away from the route, off it, or past a turn.
    case wrongDirection
    /// The path ahead is blocked with no way round (Route Blocked Ahead).
    case routeBlocked
    /// A sign or street feature nearby.
    case feature
    /// A new route has loaded mid-trip (Trip Information Loaded).
    case routeReady

    /// The spec's system haptic for this meaning; nil when an AHAP file plays instead.
    var systemHaptic: InteractionHaptic? {
        switch self {
        case .arrived, .routeReady: .success
        case .turnLeft, .turnRight: .light
        // Obstruction Ahead → Warning, however close the obstacle is.
        case .obstacleNear, .obstacleNearer, .stop, .wrongDirection, .routeBlocked: .warning
        case .feature: .medium
        default: nil
        }
    }

    var ahapFileName: String { rawValue }

    var ahapURL: URL? {
        Bundle.main.url(forResource: ahapFileName, withExtension: "ahap")
    }
    
    /// Only for AHAP patterns; the obstacle warnings that used to loop now play the system warning once.
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
        case .wrongDirection: "Wrong direction"
        case .routeBlocked: "Route blocked"
        case .feature: "Nearby feature"
        case .routeReady: "New route"
        }
    }

    /// Describes how the pattern feels, for the Practice screen.
    var patternDescription: String {
        switch self {
        case .turnLeft, .turnRight: "One light tap"
        case .onRouteHeartbeat: "A gentle double tap every few seconds"
        case .arrived, .routeReady: "The system success tap: two quick taps, the second stronger"
        case .attention: "One sharp tap"
        case .error: "Three dull buzzes getting weaker"
        case .obstacleNear, .obstacleNearer, .stop, .wrongDirection, .routeBlocked:
            "The system warning tap: two quick taps, the second weaker"
        case .feature: "One medium tap"
        }
    }
}
