import ARKit
import Foundation

/// Where geo-tracking puts the camera (AR-2): ARKit matching Apple's street imagery, for a position and heading
/// sharper than GPS and the compass. Sent about once a second, and only while the session geo-tracks.
struct GeoTrackingUpdate: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case initializing, localizing, localized, notAvailable
        /// The session stopped geo-tracking: it paused, went back to world tracking, or a call took the camera.
        /// Nothing more comes until it geo-tracks again.
        case stopped
    }

    /// Why ARKit is in its state, e.g. why it isn't localized yet.
    enum StateReason: Equatable, Sendable {
        case notAvailableAtLocation, needLocationPermissions, worldTrackingUnstable, waitingForLocation
        case waitingForAvailabilityCheck, geoDataNotLoaded, devicePointedTooLow, visualLocalizationFailed
        /// A reason this version of the app doesn't know.
        case other
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
    /// When the camera captured the frame this describes, not when the update was sent: the coordinate comes back
    /// from ARKit a little later. For `.stopped`, when tracking stopped.
    var timestamp: Date
    /// nil when ARKit gives none, and for `.stopped`.
    var stateReason: StateReason?
}

/// Lets a trip ask the shared camera session for geo-tracking (AR-2).
protocol GeoTrackingProviding: Sendable {
    /// Asks for geo-tracking from the session's next start (true), or gives it back (false). Calls nest like the
    /// scene's `start()`/`stop()`. Ask only where `ARSessionManager.isGeoTrackingAvailableHere` said yes; the
    /// session doesn't check again. A session already running keeps its tracking, so the world CV has mapped isn't
    /// reset under it.
    func setGeoTrackingWanted(_ wanted: Bool) async
    func geoTrackingUpdates() -> AsyncStream<GeoTrackingUpdate>
}

/// Which ARKit configuration the shared session runs.
enum SessionTracking: Equatable, Sendable {
    case world, geo

    /// Geo-tracking can't build the classified mesh, so finding doors wins over a sharper position, but only on a
    /// device that can build the mesh at all.
    static func choose(geoWanted: Bool, meshWanted: Bool, meshSupported: Bool) -> SessionTracking {
        geoWanted && !(meshWanted && meshSupported) ? .geo : .world
    }

    /// Whether going from `previous` to `next` (nil: not running) ends geo-tracking, which geo listeners are told.
    static func endsGeoTracking(from previous: SessionTracking?, to next: SessionTracking?) -> Bool {
        previous == .geo && next != .geo
    }
}

/// Which run of the shared session geo updates may come from (AR-2).
struct GeoSession: Equatable, Sendable {
    /// Bumped on every start, stop and call.
    private(set) var generation = 0
    private(set) var isGeoTracking = false
    /// System uptime, as `ARFrame.timestamp` counts it, when the session last started.
    private(set) var startedAt: TimeInterval = .infinity

    /// Records a start at `uptime` with `tracking`, or a stop (nil).
    mutating func begin(_ tracking: SessionTracking?, at uptime: TimeInterval) {
        generation += 1
        isGeoTracking = tracking == .geo
        startedAt = tracking == nil ? .infinity : uptime
    }

    /// Whether a frame captured at `frameTimestamp` belongs to this run's geo-tracking. ARKit can hand over a frame
    /// it queued before a pause or restart; that frame was captured before this run started.
    func accepts(frameTimestamp: TimeInterval) -> Bool {
        isGeoTracking && frameTimestamp >= startedAt
    }
}

extension GeoTrackingUpdate {
    /// The moment an `ARFrame` was captured. Its `timestamp` counts seconds of system uptime, as
    /// `ProcessInfo.systemUptime` does, so it is placed that far before or after `now`.
    static func date(
        ofFrameTimestamp timestamp: TimeInterval,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        now: Date = .now
    ) -> Date {
        now.addingTimeInterval(timestamp - uptime)
    }

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

extension GeoTrackingUpdate.StateReason {
    /// nil for ARKit's `.none`.
    init?(_ reason: ARGeoTrackingStatus.StateReason) {
        switch reason {
        case .none: return nil
        case .notAvailableAtLocation: self = .notAvailableAtLocation
        case .needLocationPermissions: self = .needLocationPermissions
        case .worldTrackingUnstable: self = .worldTrackingUnstable
        case .waitingForLocation: self = .waitingForLocation
        case .waitingForAvailabilityCheck: self = .waitingForAvailabilityCheck
        case .geoDataNotLoaded: self = .geoDataNotLoaded
        case .devicePointedTooLow: self = .devicePointedTooLow
        case .visualLocalizationFailed: self = .visualLocalizationFailed
        @unknown default: self = .other
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
