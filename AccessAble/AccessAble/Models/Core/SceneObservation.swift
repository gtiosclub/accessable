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
    /// Metres from the camera, if known (LiDAR / depth). nil on non-LiDAR devices.
    var distance: Double?
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
        self.bearing = bearing
        self.origin = origin
        self.isHazard = isHazard
        self.worldPosition = worldPosition
    }
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
