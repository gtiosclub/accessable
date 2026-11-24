import Foundation
import Synchronization

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

    /// How many extra times navigation repeats its latest instruction (T49).
    var repeatCount: Int {
        switch self {
        case .onlyWhenAsked: 0
        case .once: 1
        case .twice: 2
        case .threeTimes: 3
        }
    }
}

/// The auto-repeat choice, read by TripManager each time it schedules a repeat. AppViewModel keeps it
/// in step with the preferences, so a change in Settings applies to the next instruction.
final class RepeatSettings: Sendable {
    private let state: Mutex<AutoRepeat>

    init(autoRepeat: AutoRepeat = .onlyWhenAsked) {
        state = Mutex(autoRepeat)
    }

    var autoRepeat: AutoRepeat {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// A kind of information the user can prioritize, hear unprompted, or get only when they ask.
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

/// Settings-page preferences that are not part of `GuidanceProfile`.
/// Saved by `AppViewModel`. Only `autoRepeat` is used so far (by navigation, T49).
struct SettingsPreferences: Codable, Hashable, Sendable {
    var phoneAimingHelp: Bool
    var usesMetricUnits: Bool
    var autoRepeat: AutoRepeat
    /// Information that goes first when several things could be announced.
    var prioritizedTopics: Set<InfoTopic>
    /// Information announced without the user asking.
    var unpromptedTopics: Set<InfoTopic>
    /// Information given when the user asks.
    var promptedTopics: Set<InfoTopic>
    var usesSystemScreenReader: Bool
    var quickSettingsEnabled: Bool

    /// Defaults for a new user. Metric follows the device's region.
    static var `default`: SettingsPreferences {
        SettingsPreferences(
            phoneAimingHelp: true,
            usesMetricUnits: Locale.current.measurementSystem == .metric,
            autoRepeat: .onlyWhenAsked,
            prioritizedTopics: [.detailedDescription, .trafficAndCrowds],
            unpromptedTopics: [.directions, .trafficAndCrowds, .openingsAndObstacles],
            promptedTopics: [.trafficAndCrowds, .signsAndText, .partiallyVisibleObjects, .structureBasics],
            usesSystemScreenReader: true,
            quickSettingsEnabled: true
        )
    }
}
