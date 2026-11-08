import Foundation

/// What the Live screen is for right now. Owner: Computer Vision (1.1).
///
/// After Apple's Magnifier detection modes: each mode runs only the parts of the pipeline it
/// needs, so the phone does less and the user hears only what they came for. Whatever the
/// mode, an obstacle close enough for "Stop" is always announced.
enum LiveMode: String, CaseIterable, Codable, Sendable {
    /// Obstacles, kerbs, crosswalks and things coming towards you, at the user's alert settings.
    case walk
    /// "Take me to…": signs and doors (the mesh) on, obstacle warnings down to "Stop".
    case find
    /// Reading signs and text aloud; obstacle warnings down to "Stop".
    case read
    /// Describe, identify, or ask about the view on request; obstacle warnings down to "Stop".
    case describe

    var title: String {
        switch self {
        case .walk: "Walk"
        case .find: "Find"
        case .read: "Read"
        case .describe: "Describe"
        }
    }

    /// OCR runs: signs for Read, room numbers and exits for Find, and the text "Describe"
    /// mentions ("Exit is visible on your left").
    var readsText: Bool { self != .walk }
    /// Signs are spoken as they are found. Describe reads text too, but only speaks when asked.
    var announcesSigns: Bool { self == .find || self == .read }
    /// ARKit's classified mesh is built, for doors. It costs camera frame rate, so only Find.
    var usesMesh: Bool { self == .find }
    /// Crosswalk stripes, street signs, approaching people and vehicles, and crowds.
    var watchesStreet: Bool { self == .walk }
    /// "Too dark", "hold steady": worth hearing while walking or reading, not otherwise.
    var givesCameraHints: Bool { self == .walk || self == .read }

    /// Whether an event from the pipeline is spoken in this mode. Walk hears everything the
    /// user's filter allowed; the others only "Stop" from the obstacle announcers, plus
    /// whatever the mode itself produces (directions, signs).
    func admits(_ event: AnnouncementEvent) -> Bool {
        guard self != .walk, event.source == .obstacleDetection else { return true }
        return event.priority == .critical
    }
}
