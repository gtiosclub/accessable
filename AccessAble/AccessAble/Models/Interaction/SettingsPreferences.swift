import Foundation

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
/// Saved by `AppViewModel`; the announcement pipeline does not read them yet.
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
    /// Names nearby places while the user holds the phone flat on the home screen and turns.
    var pointToScan: Bool

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
            quickSettingsEnabled: true,
            pointToScan: false
        )
    }
}

// Settings saved before a field existed still load, with that field's default.
extension SettingsPreferences {
    private enum CodingKeys: String, CodingKey {
        case phoneAimingHelp, usesMetricUnits, autoRepeat, prioritizedTopics, unpromptedTopics, promptedTopics,
             usesSystemScreenReader, quickSettingsEnabled, pointToScan
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            phoneAimingHelp: try container.decodeIfPresent(Bool.self, forKey: .phoneAimingHelp) ?? true,
            usesMetricUnits: try container.decodeIfPresent(Bool.self, forKey: .usesMetricUnits)
                ?? (Locale.current.measurementSystem == .metric),
            autoRepeat: try container.decodeIfPresent(AutoRepeat.self, forKey: .autoRepeat) ?? .onlyWhenAsked,
            prioritizedTopics: try container.decodeIfPresent(Set<InfoTopic>.self, forKey: .prioritizedTopics)
                ?? [.detailedDescription, .trafficAndCrowds],
            unpromptedTopics: try container.decodeIfPresent(Set<InfoTopic>.self, forKey: .unpromptedTopics)
                ?? [.directions, .trafficAndCrowds, .openingsAndObstacles],
            promptedTopics: try container.decodeIfPresent(Set<InfoTopic>.self, forKey: .promptedTopics)
                ?? [.trafficAndCrowds, .signsAndText, .partiallyVisibleObjects, .structureBasics],
            usesSystemScreenReader: try container.decodeIfPresent(Bool.self, forKey: .usesSystemScreenReader) ?? true,
            quickSettingsEnabled: try container.decodeIfPresent(Bool.self, forKey: .quickSettingsEnabled) ?? true,
            pointToScan: try container.decodeIfPresent(Bool.self, forKey: .pointToScan) ?? false
        )
    }
}
