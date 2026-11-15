import Foundation

/// Something the camera recognized that Maps can match to the route (LAND-1). CV detects it; Maps decides whether
/// it confirms progress, the destination, or an entrance.
struct LandmarkObservation: Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A sign or plate with readable text, such as a building name.
        case signText
        /// A door, or a sign saying entrance.
        case entrance
        case crosswalk
        case stairs
        case elevator
        /// Anything else with a name worth matching, such as a bike rack or bench.
        case namedObject
    }

    var kind: Kind
    /// The sign's text as read, its lines joined with spaces, or the object's label. nil for a door with no sign.
    var text: String?
    /// The same physical landmark keeps its key across frames, so repeats can be counted and deduplicated.
    var key: String
    /// Relative to where the camera points. nil when depth didn't place it.
    var bearing: RelativeBearing?
    /// Metres from the camera.
    var distance: Double?
    var distanceAccuracy: DistanceAccuracy?
    var confidence: Float
    /// True when CV already spoke it (a sign through `SignAnnouncer`), so Maps doesn't repeat the name.
    var wasAnnounced: Bool
    var timestamp: Date

    init(
        kind: Kind,
        text: String? = nil,
        key: String,
        bearing: RelativeBearing? = nil,
        distance: Double? = nil,
        distanceAccuracy: DistanceAccuracy? = nil,
        confidence: Float,
        wasAnnounced: Bool = false,
        timestamp: Date = .now
    ) {
        self.kind = kind
        self.text = text
        self.key = key
        self.bearing = bearing
        self.distance = distance
        self.distanceAccuracy = distanceAccuracy
        self.confidence = confidence
        self.wasAnnounced = wasAnnounced
        self.timestamp = timestamp
    }
}
