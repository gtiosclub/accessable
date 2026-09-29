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
    var trackID: Int?
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

    init(
        id: UUID = UUID(),
        trackID: Int? = nil,
        label: String,
        confidence: Float,
        boundingBox: CGRect,
        distance: Double? = nil,
        bearing: RelativeBearing? = nil,
        origin: Origin,
        isHazard: Bool
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

    init(id: UUID = UUID(), string: String, confidence: Float, boundingBox: CGRect) {
        self.id = id
        self.string = string
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// Everything the CV pipeline (SceneAnalyzer) knows about one analyzed frame.
struct SceneObservation: Equatable, Sendable {
    var timestamp: Date
    var detections: [Detection]
    var ground: GroundSurface
    var recognizedText: [RecognizedText]
    /// False when distances came from relative depth or were unavailable.
    var hasMetricDepth: Bool

    init(
        timestamp: Date = .now,
        detections: [Detection] = [],
        ground: GroundSurface = .unknown,
        recognizedText: [RecognizedText] = [],
        hasMetricDepth: Bool = false
    ) {
        self.timestamp = timestamp
        self.detections = detections
        self.ground = ground
        self.recognizedText = recognizedText
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
