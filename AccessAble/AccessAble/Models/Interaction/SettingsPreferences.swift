import Foundation

/// Settings-page preferences that are not part of `GuidanceProfile`.
///
/// What the announcement pipeline reads lives in `GuidanceProfile`, which the engine is
/// already given through `updateProfile`: the topic lists and the repeat limit moved there
/// for T50. What is left here is read by the UI.
struct SettingsPreferences: Codable, Hashable, Sendable {
    var phoneAimingHelp: Bool
    var usesMetricUnits: Bool
    var usesSystemScreenReader: Bool
    var quickSettingsEnabled: Bool

    /// Defaults for a new user. Metric follows the device's region.
    static var `default`: SettingsPreferences {
        SettingsPreferences(
            phoneAimingHelp: true,
            usesMetricUnits: Locale.current.measurementSystem == .metric,
            usesSystemScreenReader: true,
            quickSettingsEnabled: true
        )
    }
}
