import CoreGraphics
import Foundation
import Testing

@testable import SceneGeometry

// T50 — how the user's announcement preferences affect what they hear.
//
// The rules under test are the ones in `GuidanceProfile`: which events pass at all, which go
// first among equals, how often one may repeat, and what an answer includes. The engine
// applies them, but the decisions live here so they can be checked without speech or an
// actor.

private func event(
    _ category: AnnouncementCategory,
    _ priority: AnnouncementPriority,
    topic: InfoTopic? = nil,
    source: AnnouncementSource = .obstacleDetection
) -> AnnouncementEvent {
    AnnouncementEvent(
        category: category, priority: priority, text: "test", source: source, topic: topic
    )
}

@Suite("T50 — what the user hears at all")
struct UnpromptedTopicTests {
    @Test("a topic the user did not ask to hear unprompted is held back")
    func unselectedTopicIsFiltered() {
        var profile = GuidanceProfile.blind
        profile.unpromptedTopics = [.directions]
        // Signs are not in the list, so the app does not volunteer them.
        #expect(!profile.allows(event(.landmark, .normal, topic: .signsAndText)))
        #expect(profile.allows(event(.maneuver, .normal, topic: .directions)))
    }

    @Test("an event with no topic is not affected by the topic lists")
    func untaggedEventsPassThrough() {
        var profile = GuidanceProfile.blind
        profile.unpromptedTopics = []
        // System messages — the camera stopping, a trip starting — carry no topic.
        #expect(profile.allows(event(.system, .normal)))
    }

    /// The line that matters most. Topic preferences describe how much detail the user
    /// wants, so they must not be able to switch a warning off.
    @Test("topic preferences cannot silence a hazard warning", arguments: [
        AnnouncementPriority.high, .critical,
    ])
    func topicsNeverSilenceWarnings(priority: AnnouncementPriority) {
        var profile = GuidanceProfile.blind
        profile.unpromptedTopics = []
        #expect(profile.allows(event(.hazard, priority, topic: .openingsAndObstacles)))
    }

    @Test("a low-priority hazard is still subject to the topic lists")
    func lowHazardsAreFilterable() {
        var profile = GuidanceProfile.blind
        profile.unpromptedTopics = []
        // Not a warning, so the preference applies: this is "path clear", not "stop".
        #expect(!profile.allows(event(.hazard, .normal, topic: .openingsAndObstacles)))
    }

    /// Switching a whole category off in Settings is deliberate, so it is honoured where a
    /// topic preference would not be.
    @Test("turning a category off is still obeyed")
    func categoryToggleWins() {
        var profile = GuidanceProfile.blind
        profile.enabledCategories = [.maneuver]
        #expect(!profile.allows(event(.hazard, .high, topic: .openingsAndObstacles)))
        // Except for critical, which was never filterable.
        #expect(profile.allows(event(.hazard, .critical, topic: .openingsAndObstacles)))
    }

    @Test("a reply to something the user asked for always passes")
    func promptedRepliesAlwaysPass() {
        var profile = GuidanceProfile.blind
        profile.unpromptedTopics = []
        profile.enabledCategories = []
        #expect(profile.allows(event(.ambient, .normal, topic: .detailedDescription, source: .userInteraction)))
    }
}

@Suite("T50 — what goes first")
struct PrioritizedTopicTests {
    @Test("a prioritized topic is preferred among equals")
    func prioritizedIsPreferred() {
        var profile = GuidanceProfile.blind
        profile.prioritizedTopics = [.directions]
        #expect(profile.prefersFirst(event(.maneuver, .normal, topic: .directions)))
        #expect(!profile.prefersFirst(event(.ambient, .normal, topic: .trafficAndCrowds)))
    }

    @Test("an untagged event is never preferred")
    func untaggedIsNotPreferred() {
        #expect(!GuidanceProfile.blind.prefersFirst(event(.system, .normal)))
    }

    /// Why preference is a tie-break and not a priority bump: `.detailedDescription` is in
    /// the default prioritized set, so promoting it would put an aesthetic description ahead
    /// of an obstacle warning for every new user.
    @Test("preferring a topic does not change how urgent it is")
    func preferenceIsNotUrgency() {
        let profile = GuidanceProfile.default
        let description = event(.ambient, .normal, topic: .detailedDescription)
        let warning = event(.hazard, .high, topic: .openingsAndObstacles)
        #expect(profile.prefersFirst(description))
        #expect(!profile.prefersFirst(warning))
        // The preference says nothing about priority, which is what orders them first.
        #expect(warning.priority > description.priority)
    }
}

@Suite("T50 — how often something repeats")
struct AutoRepeatTests {
    @Test("the limit follows the setting", arguments: [
        (AutoRepeat.onlyWhenAsked, 0), (.once, 1), (.twice, 2), (.threeTimes, 3),
    ])
    func limitFollowsSetting(setting: AutoRepeat, expected: Int) {
        var profile = GuidanceProfile.blind
        profile.autoRepeat = setting
        #expect(profile.repeatLimit(for: event(.ambient, .normal, topic: .trafficAndCrowds)) == expected)
    }

    /// A "Stop" that cannot repeat itself is worse than useless.
    @Test("safety warnings and answers are never capped")
    func exemptions() {
        var profile = GuidanceProfile.blind
        profile.autoRepeat = .onlyWhenAsked
        #expect(profile.repeatLimit(for: event(.hazard, .high, topic: .openingsAndObstacles)) == nil)
        #expect(profile.repeatLimit(for: event(.hazard, .critical, topic: .openingsAndObstacles)) == nil)
        #expect(profile.repeatLimit(for: event(.ambient, .normal, source: .userInteraction)) == nil)
    }

    @Test("the default setting still lets something be said once")
    func onlyWhenAskedStillSpeaksOnce() {
        // "Only when I ask" caps repeats, not the first utterance: the setting is about
        // repetition, so it must not silence an announcement outright.
        #expect(GuidanceProfile.default.autoRepeat == .onlyWhenAsked)
        #expect(AutoRepeat.onlyWhenAsked.allowedRepeats == 0)
    }
}

@Suite("T50 — what an answer includes")
struct PromptedTopicTests {
    private func observation() -> SceneObservation {
        let chair = Detection(
            label: "chair", confidence: 0.9,
            boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.1, height: 0.3),
            distance: 1.5, bearing: .ahead, origin: .model, isHazard: true
        )
        let door = Detection(
            label: "door", confidence: 0.9,
            boundingBox: CGRect(x: 0.6, y: 0.3, width: 0.1, height: 0.4),
            distance: 3, bearing: .ahead, origin: .model, isHazard: false
        )
        return SceneObservation(
            detections: [chair, door],
            recognizedText: [RecognizedText(
                string: "Exit", confidence: 0.9,
                boundingBox: CGRect(x: 0.7, y: 0.2, width: 0.2, height: 0.1)
            )]
        )
    }

    @Test("by default an answer covers the hazard, the object and the sign")
    func defaultAnswerIsFull() {
        let text = SceneDescriptionBuilder().describe(observation())
        #expect(text.contains("Chair"))
        #expect(text.contains("Door"))
        #expect(text.contains("Exit"))
    }

    @Test("dropping signs from the prompted list leaves them out of the answer")
    func signsCanBeLeftOut() {
        var profile = GuidanceProfile.default
        profile.promptedTopics.remove(.signsAndText)
        let text = SceneDescriptionBuilder(profile: profile).describe(observation())
        #expect(!text.contains("Exit"))
        #expect(text.contains("Chair"))
    }

    /// An answer to "what is around me" always names what could hurt the user. Leaving that
    /// out would not be a preference.
    @Test("an answer always includes the hazard, whatever the lists say")
    func hazardsAreNotOptional() {
        var profile = GuidanceProfile.default
        profile.promptedTopics = []
        let text = SceneDescriptionBuilder(profile: profile).describe(observation())
        #expect(text.contains("Chair"))
        #expect(!text.contains("Door"))
        #expect(!text.contains("Exit"))
    }

    /// Prompted and unprompted are different questions: one is "may the app volunteer this",
    /// the other is "what goes in a reply". Confusing them would silence direct answers.
    @Test("the unprompted list has no say over what an answer contains")
    func unpromptedDoesNotShapeAnswers() {
        var profile = GuidanceProfile.default
        profile.unpromptedTopics = []
        let text = SceneDescriptionBuilder(profile: profile).describe(observation())
        #expect(text.contains("Exit"))
    }
}

@Suite("T50 — preferences saved before T50 existed")
struct ProfileMigrationTests {
    @Test("an older profile loads with the default lists, not empty ones")
    func olderProfileGetsDefaults() throws {
        // A profile encoded before the topic lists were added. Decoding it to empty sets
        // would read as "the user wants to hear nothing".
        let json = """
        {
          "visionLevel": "blind",
          "channels": 3,
          "verbosity": "active",
          "speechRate": 0.5,
          "hapticIntensity": 1,
          "enabledCategories": ["hazard", "maneuver", "landmark", "ambient", "system"]
        }
        """
        let profile = try JSONDecoder().decode(GuidanceProfile.self, from: Data(json.utf8))
        #expect(profile.unpromptedTopics == GuidanceProfile.default.unpromptedTopics)
        #expect(profile.promptedTopics == GuidanceProfile.default.promptedTopics)
        #expect(profile.prioritizedTopics == GuidanceProfile.default.prioritizedTopics)
        #expect(profile.autoRepeat == GuidanceProfile.default.autoRepeat)
    }

    @Test("a profile survives a round trip with the new fields")
    func roundTrip() throws {
        var profile = GuidanceProfile.lowVision
        profile.unpromptedTopics = [.signsAndText]
        profile.autoRepeat = .twice
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(GuidanceProfile.self, from: data)
        #expect(decoded == profile)
    }
}
