import Foundation

// Phase 0 shared contract for announcement preferences (3.3 / task T50).
//
// These two live in Core rather than beside `SettingsPreferences` because
// `AnnouncementEvent` and `GuidanceProfile` both name them: the event says which kind of
// information it carries, and the profile says what the user wants done with that kind.

/// A kind of information the user can prioritize, hear unprompted, or get only when they ask.
///
/// One topic covers several producers — a crowd (T35) and a vehicle approaching (T34) are
/// both `trafficAndCrowds` — so topics are deliberately coarser than
/// `AnnouncementCategory`. They describe what the user is interested in, not how urgent it is.
enum InfoTopic: String, Codable, CaseIterable, Sendable {
    case directions
    case trafficAndCrowds
    case openingsAndObstacles
    case signsAndText
    case partiallyVisibleObjects
    case structureBasics
    case detailedDescription

    var displayName: String {
        switch self {
        case .directions: "Directions"
        case .trafficAndCrowds: "Traffic flow and crowd density"
        case .openingsAndObstacles: "Opening areas and obstacles"
        case .signsAndText: "Locations and styles of recognized signs/texts in view"
        case .partiallyVisibleObjects: "Objects that are partly in view and which way to move to capture them."
        case .structureBasics: "Basic information (size, distance, color) of structures and buildings."
        case .detailedDescription: "Detailed description of view (includes aesthetic appearances)"
        }
    }
}

/// How many times an unprompted announcement repeats before it waits for the user to ask again.
enum AutoRepeat: String, Codable, CaseIterable, Sendable {
    case onlyWhenAsked
    case once
    case twice
    case threeTimes

    var displayName: String {
        switch self {
        case .onlyWhenAsked: "Only when I ask"
        case .once: "Once"
        case .twice: "Twice"
        case .threeTimes: "Three times"
        }
    }

    /// How many repeats of the same announcement are allowed after the first one.
    var allowedRepeats: Int {
        switch self {
        case .onlyWhenAsked: 0
        case .once: 1
        case .twice: 2
        case .threeTimes: 3
        }
    }
}
