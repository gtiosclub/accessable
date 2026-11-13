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
    /// What Ask AI mentions first (T23). Close hazards come first regardless.
    var aiPriorities: AIPriorities = .default
    /// What the camera warns about: the danger bar and warning distance, set on the Live
    /// detection screen.
    var alertFilter: AlertFilter = .default
    /// Kinds of information that go first when several things could be announced at once (T50).
    var prioritizedTopics: Set<InfoTopic> = [.detailedDescription, .trafficAndCrowds]
    /// Kinds of information the app may volunteer, without being asked.
    var unpromptedTopics: Set<InfoTopic> = [.directions, .trafficAndCrowds, .openingsAndObstacles]
    /// Kinds of information an answer includes when the user does ask.
    var promptedTopics: Set<InfoTopic> = [
        .trafficAndCrowds, .signsAndText, .partiallyVisibleObjects, .structureBasics,
    ]
    /// How often an unprompted announcement may repeat itself.
    var autoRepeat: AutoRepeat = .onlyWhenAsked

    /// Whether this profile wants to hear an event at all.
    ///
    /// Three things pass whatever the settings say: a `.critical` event, a reply to
    /// something the user just asked for, and a hazard at `.high` or above.
    ///
    /// That last exemption applies to the topic lists only, not to `enabledCategories`.
    /// Topics say how much detail the user wants, so letting one silence a warning would be
    /// a safety setting disguised as a preference about information. Switching a whole
    /// category off in Settings is a different matter: that is deliberate, and it is honoured.
    func allows(_ event: AnnouncementEvent) -> Bool {
        if event.priority == .critical || event.source == .userInteraction { return true }
        guard enabledCategories.contains(event.category) else { return false }
        if !isSafetyWarning(event), let topic = event.topic, !unpromptedTopics.contains(topic) {
            return false
        }
        switch verbosity {
        case .passive: return event.priority >= .high
        case .active: return true
        }
    }

    /// Whether the user asked to hear this kind of thing first.
    ///
    /// Used only to order events that are already equally urgent. A preference never
    /// outranks a more urgent announcement, which matters here: `.detailedDescription` is in
    /// the default prioritized set, and promoting it over an obstacle warning would be
    /// exactly the wrong trade.
    func prefersFirst(_ event: AnnouncementEvent) -> Bool {
        guard let topic = event.topic else { return false }
        return prioritizedTopics.contains(topic)
    }

    /// How many times this announcement may repeat after the first time it is spoken; nil
    /// for no limit.
    ///
    /// Safety warnings and answers the user asked for are never capped — a "Stop" that
    /// cannot repeat itself is worse than useless.
    func repeatLimit(for event: AnnouncementEvent) -> Int? {
        if event.source == .userInteraction || isSafetyWarning(event) { return nil }
        if event.priority == .critical { return nil }
        return autoRepeat.allowedRepeats
    }

    /// Whether an answer the user asked for should include this kind of information.
    ///
    /// Deliberately separate from `unpromptedTopics`: one decides whether the app volunteers
    /// something, the other decides what goes into a reply. Making them one filter would let
    /// a preference silence the answer to a direct question.
    func answerIncludes(_ topic: InfoTopic) -> Bool {
        promptedTopics.contains(topic)
    }

    private func isSafetyWarning(_ event: AnnouncementEvent) -> Bool {
        event.category == .hazard && event.priority >= .high
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

// Profiles saved before a field existed still load, with that field's default, instead of
// failing to decode and resetting the user's settings.
extension GuidanceProfile {
    private enum CodingKeys: String, CodingKey {
        case visionLevel, channels, verbosity, speechRate, hapticIntensity, enabledCategories, aiPriorities, alertFilter
        case prioritizedTopics, unpromptedTopics, promptedTopics, autoRepeat
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            visionLevel: try container.decode(VisionLevel.self, forKey: .visionLevel),
            channels: try container.decode(GuidanceChannels.self, forKey: .channels),
            verbosity: try container.decode(Verbosity.self, forKey: .verbosity),
            speechRate: try container.decode(Float.self, forKey: .speechRate),
            hapticIntensity: try container.decode(Float.self, forKey: .hapticIntensity),
            enabledCategories: try container.decode(Set<AnnouncementCategory>.self, forKey: .enabledCategories),
            aiPriorities: try container.decodeIfPresent(AIPriorities.self, forKey: .aiPriorities) ?? .default,
            alertFilter: try container.decodeIfPresent(AlertFilter.self, forKey: .alertFilter) ?? .default
        )
        // Saved before T50: fall back to the defaults rather than to empty sets, which would
        // read as "the user wants to hear nothing".
        let fallback = GuidanceProfile.default
        prioritizedTopics = try container.decodeIfPresent(Set<InfoTopic>.self, forKey: .prioritizedTopics)
            ?? fallback.prioritizedTopics
        unpromptedTopics = try container.decodeIfPresent(Set<InfoTopic>.self, forKey: .unpromptedTopics)
            ?? fallback.unpromptedTopics
        promptedTopics = try container.decodeIfPresent(Set<InfoTopic>.self, forKey: .promptedTopics)
            ?? fallback.promptedTopics
        autoRepeat = try container.decodeIfPresent(AutoRepeat.self, forKey: .autoRepeat) ?? fallback.autoRepeat
    }
}
