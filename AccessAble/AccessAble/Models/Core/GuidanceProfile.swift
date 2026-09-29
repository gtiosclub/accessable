import Foundation

enum VisionLevel: String, Codable, CaseIterable, Sendable {
    case blind
    case lowVision
    case sighted

    var displayName: String {
        switch self {
        case .blind: "Blind"
        case .lowVision: "Low vision"
        case .sighted: "Sighted helper"
        }
    }
}

/// Output channels the user wants guidance through.
struct GuidanceChannels: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let speech = GuidanceChannels(rawValue: 1 << 0)
    static let haptics = GuidanceChannels(rawValue: 1 << 1)
    static let spatialAudio = GuidanceChannels(rawValue: 1 << 2)
}

enum Verbosity: String, Codable, CaseIterable, Sendable {
    /// Critical + high priority only.
    case passive
    /// Everything in `enabledCategories`.
    case active
}

/// The user's guidance preferences. Produced by onboarding (3.4), edited in Settings,
/// read by the AnnouncementEngine (3.3) and anything that renders output.
struct GuidanceProfile: Codable, Hashable, Sendable {
    var visionLevel: VisionLevel
    var channels: GuidanceChannels
    var verbosity: Verbosity
    /// AVSpeechUtterance rate, 0...1 (AVSpeechUtteranceDefaultSpeechRate is 0.5).
    var speechRate: Float
    /// Core Haptics intensity multiplier, 0...1.
    var hapticIntensity: Float
    var enabledCategories: Set<AnnouncementCategory>

    /// Whether this profile wants to hear an event at all. Critical events always pass.
    func allows(_ event: AnnouncementEvent) -> Bool {
        if event.priority == .critical { return true }
        guard enabledCategories.contains(event.category) else { return false }
        switch verbosity {
        case .passive: return event.priority >= .high
        case .active: return true
        }
    }
}

extension GuidanceProfile {
    /// Speech + haptics; suggest Screen Curtain during onboarding.
    static let blind = GuidanceProfile(
        visionLevel: .blind,
        channels: [.speech, .haptics],
        verbosity: .active,
        speechRate: 0.5,
        hapticIntensity: 1.0,
        enabledCategories: Set(AnnouncementCategory.allCases)
    )

    /// High contrast + large text in the UI, speech for guidance.
    static let lowVision = GuidanceProfile(
        visionLevel: .lowVision,
        channels: [.speech],
        verbosity: .active,
        speechRate: 0.5,
        hapticIntensity: 0.7,
        enabledCategories: Set(AnnouncementCategory.allCases)
    )

    /// Visual map first; only important cues are spoken.
    static let sightedHelper = GuidanceProfile(
        visionLevel: .sighted,
        channels: [.speech],
        verbosity: .passive,
        speechRate: 0.5,
        hapticIntensity: 0.5,
        enabledCategories: [.hazard, .maneuver, .system]
    )

    static func preset(for level: VisionLevel) -> GuidanceProfile {
        switch level {
        case .blind: .blind
        case .lowVision: .lowVision
        case .sighted: .sightedHelper
        }
    }

    static let `default` = GuidanceProfile.blind
}
