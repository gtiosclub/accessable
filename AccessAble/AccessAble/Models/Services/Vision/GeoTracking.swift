import ARKit
import Foundation

/// Where geo-tracking puts the camera (AR-2): ARKit matching Apple's street imagery, for a position and heading
/// sharper than GPS and the compass. Sent about once a second, and only while the session geo-tracks.
struct GeoTrackingUpdate: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case initializing, localizing, localized, notAvailable
    }

    /// In increasing order, so `>= .medium` reads as "medium or better".
    enum Accuracy: Comparable, Sendable {
        case undetermined, low, medium, high
    }

    var state: State
    var accuracy: Accuracy
    /// Only once localized.
    var coordinate: GeoCoordinate?
    /// Metres above sea level.
    var altitude: Double?
    /// Degrees clockwise from true north that the camera faces, 0..<360. Only once localized, and nil while the
    /// camera points almost straight up or down.
    var heading: Double?
    var timestamp: Date
}

/// Lets a trip ask the shared camera session for geo-tracking (AR-2).
protocol GeoTrackingProviding: Sendable {
    /// Starts finding out, in the background, whether Apple has geo-tracking imagery here, and returns at once.
    /// Call it while a trip is being planned, so the answer is in before the camera starts.
    func prepareGeoTracking() async
    /// Whether the session should geo-track from its next start, where Apple supports it here. Returns at once:
    /// if the answer from `prepareGeoTracking()` isn't in yet, the session starts with world tracking rather
    /// than hold obstacle warnings up. A session already running keeps its tracking, so the world CV has mapped
    /// isn't reset under it.
    func setGeoTrackingWanted(_ wanted: Bool) async
    func geoTrackingUpdates() -> AsyncStream<GeoTrackingUpdate>
}

/// Which ARKit configuration the shared session runs.
enum SessionTracking: Equatable, Sendable {
    case world, geo

    /// Geo-tracking only where Apple is known to have imagery (`geoAvailable` is true, not unknown), and never
    /// while the mesh is wanted: geo-tracking can't build it, and finding doors wins over a sharper position.
    static func choose(geoWanted: Bool, geoAvailable: Bool?, meshWanted: Bool) -> SessionTracking {
        geoWanted && geoAvailable == true && !meshWanted ? .geo : .world
    }
}

/// Apple's answer to "is there geo-tracking imagery here", kept so the camera never waits on it.
struct GeoAvailability: Equatable, Sendable {
    var isAvailable: Bool
    var checkedAt: Date

    /// Coverage is by city, so an answer holds for a walk; past this it is checked again.
    static let lifetime: TimeInterval = 10 * 60

    func isFresh(at now: Date) -> Bool { now.timeIntervalSince(checkedAt) < Self.lifetime }
}

extension GeoTrackingUpdate {
    /// Degrees clockwise from true north of the camera's view. Geo-tracking's world is east-up-south, so north is
    /// -z; the camera looks down its own -z.
    static func heading(cameraTransform transform: simd_float4x4) -> Double? {
        let forward = -SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        // under about 15° from vertical the horizontal part is mostly noise
        guard (forward.x * forward.x + forward.z * forward.z).squareRoot() >= 0.25 else { return nil }
        let degrees = atan2(Double(forward.x), Double(-forward.z)) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}

extension GeoTrackingUpdate.State {
    init(_ state: ARGeoTrackingStatus.State) {
        self = switch state {
        case .initializing: .initializing
        case .localizing: .localizing
        case .localized: .localized
        case .notAvailable: .notAvailable
        @unknown default: .notAvailable
        }
    }
}

extension GeoTrackingUpdate.Accuracy {
    init(_ accuracy: ARGeoTrackingStatus.Accuracy) {
        self = switch accuracy {
        case .low: .low
        case .medium: .medium
        case .high: .high
        case .undetermined: .undetermined
        @unknown default: .undetermined
        }
    }
}
