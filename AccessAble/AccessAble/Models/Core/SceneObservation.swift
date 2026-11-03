import CoreGraphics
import Foundation

/// One thing the camera pipeline found in a frame.
struct Detection: Identifiable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable {
        /// Class-agnostic: something rising above the floor inside the walking corridor (1.1 primary).
        case geometric
        /// Object-detection model (YOLO, Vision built-ins).
        case model
        /// ARKit mesh classification (door, wall, window, seat, table...).
        case mesh
    }

    let id: UUID
    /// Stable across frames when tracked, so announcements fire on entry/threshold crossings only.
    var trackID: UUID?
    /// e.g. "person", "chair", "door", "obstacle", "drop-off".
    var label: String
    var confidence: Float
    /// Normalized (0...1), upright orientation, origin at top-left.
    var boundingBox: CGRect
    /// Metres from the camera, if known. Measured from depth on LiDAR devices, estimated
    /// from scene geometry elsewhere (T33); `distanceAccuracy` says which.
    var distance: Double?
    /// How far `distance` can be trusted. nil when there is no distance.
    var distanceAccuracy: DistanceAccuracy?
    var bearing: RelativeBearing?
    var origin: Origin
    /// True for things the user could walk into or fall off.
    var isHazard: Bool
    /// Where it is in ARKit's gravity-aligned world, in metres, when depth placed it. Stable
    /// while tracking runs, so a thing seen once can be steered towards after looking away.
    var worldPosition: SIMD3<Float>?

    init(
        id: UUID = UUID(),
        trackID: UUID? = nil,
        label: String,
        confidence: Float,
        boundingBox: CGRect,
        distance: Double? = nil,
        distanceAccuracy: DistanceAccuracy? = nil,
        bearing: RelativeBearing? = nil,
        origin: Origin,
        isHazard: Bool,
        worldPosition: SIMD3<Float>? = nil
    ) {
        self.id = id
        self.trackID = trackID
        self.label = label
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.distance = distance
        self.distanceAccuracy = distanceAccuracy
        self.bearing = bearing
        self.origin = origin
        self.isHazard = isHazard
        self.worldPosition = worldPosition
    }
}

/// How much a `Detection.distance` can be trusted.
///
/// LiDAR depth is a measurement. A distance worked out from where an object meets the floor,
/// or from how large something of known size appears, is an estimate that can be out by tens
/// of percent. Anything acting on a distance — announcement bands, spoken phrasing — has to
/// be able to tell the two apart, or a guess is reported in the same voice as a measurement.
enum DistanceAccuracy: Hashable, Codable, Sendable {
    /// Measured by the depth sensor.
    case measured
    /// Inferred from geometry. `plusMinus` is the one-standard-deviation uncertainty in metres.
    case estimated(plusMinus: Double)
}

/// What the user is walking on, at camera level.
enum GroundSurface: String, Codable, CaseIterable, Sendable {
    case unknown
    case sidewalk
    case road
    case grass
    case tactilePaving
    case stairs
    case dropOff
}

struct RecognizedText: Identifiable, Equatable, Sendable {
    let id: UUID
    var string: String
    var confidence: Float
    /// Normalized (0...1), upright orientation, origin at top-left.
    var boundingBox: CGRect
    /// Where the text is in the world, in metres, when depth placed it at read time.
    var worldPosition: SIMD3<Float>?

    init(id: UUID = UUID(), string: String, confidence: Float, boundingBox: CGRect, worldPosition: SIMD3<Float>? = nil) {
        self.id = id
        self.string = string
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.worldPosition = worldPosition
    }
}

/// Everything the CV pipeline (SceneAnalyzer) knows about one analyzed frame.
struct SceneObservation: Equatable, Sendable {
    var timestamp: Date
    var detections: [Detection]
    var ground: GroundSurface
    var recognizedText: [RecognizedText]
    /// Kerbs, steps and drop-offs in the walking surface ahead, nearest first. Empty without LiDAR.
    var elevationHazards: [ElevationHazard]
    /// False when distances came from relative depth or were unavailable.
    var hasMetricDepth: Bool

    init(
        timestamp: Date = .now,
        detections: [Detection] = [],
        ground: GroundSurface = .unknown,
        recognizedText: [RecognizedText] = [],
        elevationHazards: [ElevationHazard] = [],
        hasMetricDepth: Bool = false
    ) {
        self.timestamp = timestamp
        self.detections = detections
        self.ground = ground
        self.recognizedText = recognizedText
        self.elevationHazards = elevationHazards
        self.hasMetricDepth = hasMetricDepth
    }

    /// Hazards first, then everything else, each sorted nearest-first. This is the order Tier A descriptions use.
    var prioritizedDetections: [Detection] {
        detections.sorted { a, b in
            if a.isHazard != b.isHazard { return a.isHazard }
            return (a.distance ?? .infinity) < (b.distance ?? .infinity)
        }
    }

    static let empty = SceneObservation()
}
