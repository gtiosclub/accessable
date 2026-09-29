import CoreLocation
import Foundation

/// Codable/Hashable stand-in for `CLLocationCoordinate2D` so models can be persisted and compared.
struct GeoCoordinate: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum TripPhase: String, Codable, Sendable {
    case planning
    case active
    case paused
    case arrived
}

enum ManeuverKind: String, Codable, Sendable {
    case depart
    case straight
    case turnLeft
    case turnRight
    case slightLeft
    case slightRight
    case uTurn
    case cross
    case arrive

    var haptic: HapticID? {
        switch self {
        case .turnLeft, .slightLeft: .turnLeft
        case .turnRight, .slightRight: .turnRight
        case .arrive: .arrived
        case .uTurn, .cross: .attention
        case .depart, .straight: nil
        }
    }
}

struct Maneuver: Codable, Hashable, Sendable {
    var kind: ManeuverKind
    /// Human-readable instruction, e.g. "Turn left onto Ferst Drive".
    var instruction: String
    var coordinate: GeoCoordinate
}

/// Snapshot of the current trip, published by the Maps subteam (2.2) and read by UI and the Live Activity.
struct TripState: Codable, Hashable, Sendable {
    var phase: TripPhase
    var destinationName: String?
    var nextManeuver: Maneuver?
    /// Metres along the route to `nextManeuver`.
    var distanceToNextManeuver: Double?
    /// Metres along the route to the destination.
    var distanceRemaining: Double?
    var updatedAt: Date

    init(
        phase: TripPhase,
        destinationName: String? = nil,
        nextManeuver: Maneuver? = nil,
        distanceToNextManeuver: Double? = nil,
        distanceRemaining: Double? = nil,
        updatedAt: Date = .now
    ) {
        self.phase = phase
        self.destinationName = destinationName
        self.nextManeuver = nextManeuver
        self.distanceToNextManeuver = distanceToNextManeuver
        self.distanceRemaining = distanceRemaining
        self.updatedAt = updatedAt
    }

    static let idle = TripState(phase: .planning)
}
