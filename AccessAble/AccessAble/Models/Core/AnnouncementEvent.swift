import Foundation

/// What kind of thing is being announced. Used for per-category toggles in `GuidanceProfile`.
enum AnnouncementCategory: String, Codable, CaseIterable, Sendable {
    case hazard     // obstacles, drop-offs, curbs (CV 1.1)
    case maneuver   // turn-by-turn cues (Maps 2.2)
    case landmark   // signs, POIs, accessibility-map callouts (CV 1.3, Maps 2.3)
    case ambient    // scene description, crowd counts, surface changes
    case system     // GPS weak, battery mode, errors, confirmations
}

/// How urgently an announcement must be delivered.
/// The AnnouncementEngine (3.3) uses this to preempt, queue, or drop.
enum AnnouncementPriority: Int, Codable, CaseIterable, Comparable, Sendable {
    case low = 0      // droppable when stale
    case normal = 1   // droppable when stale
    case high = 2     // queued ahead of normal/low
    case critical = 3 // interrupts whatever is speaking (e.g. hazard < 1.5 m)

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Which part of the app produced an announcement. Useful for logging and debugging.
enum AnnouncementSource: String, Codable, Sendable {
    case obstacleDetection  // 1.1
    case sceneDescription   // 1.3 Tier A / Tier B
    case textRecognition    // 1.3 OCR
    case navigation         // 2.2
    case accessibilityMap   // 2.3
    case location           // 2.1 / 2.4 (e.g. "GPS is weak")
    case userInteraction    // 3.1 voice commands, confirmations
    case system
}

/// The single contract every subteam uses to say something to the user.
/// Producers (CV, Maps) create these; the AnnouncementEngine (3.3) decides when and how to render them
/// as speech, haptics, and/or spatial audio.
struct AnnouncementEvent: Identifiable, Hashable, Sendable {
    let id: UUID
    var category: AnnouncementCategory
    var priority: AnnouncementPriority
    /// Exactly what should be spoken. Keep it short; hazards first.
    var text: String
    var haptic: HapticID?
    /// Where the thing is relative to the user's facing direction, if known. Drives spatial audio.
    var bearing: RelativeBearing?
    var source: AnnouncementSource
    var createdAt: Date
    /// After this time the event is stale and the engine may drop it without speaking.
    var expiresAt: Date?
    /// Events with the same key are treated as duplicates (e.g. "track-12@2m").
    var dedupKey: String?

    init(
        id: UUID = UUID(),
        category: AnnouncementCategory,
        priority: AnnouncementPriority,
        text: String,
        haptic: HapticID? = nil,
        bearing: RelativeBearing? = nil,
        source: AnnouncementSource,
        createdAt: Date = .now,
        expiresAt: Date? = nil,
        dedupKey: String? = nil
    ) {
        self.id = id
        self.category = category
        self.priority = priority
        self.text = text
        self.haptic = haptic
        self.bearing = bearing
        self.source = source
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.dedupKey = dedupKey
    }

    func isExpired(at date: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return date >= expiresAt
    }
}
