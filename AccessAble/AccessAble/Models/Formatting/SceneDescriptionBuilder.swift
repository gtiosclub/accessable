import CoreGraphics
import Foundation
import Synchronization

/// The instant, offline answer to "Describe my surroundings" (Tier A).
/// Owner: Computer Vision (1.3 / task T18).
///
/// Surface hazards come first, then hazards nearest-first, then any crowd, then everything
/// else, then any text in view. Only the first `maxItems` are spoken: a scene can hold
/// dozens of things, and the user needs the few that matter, not an inventory.
///
/// Groups of people collapse into one sentence (T35). Without that, six people spend the
/// whole sentence budget on "Person 3 metres ahead" four times over, and the door, the sign
/// and every piece of recognized text behind them are never said.
struct SceneDescriptionBuilder: Sendable {
    var maxItems = 4
    var crowdTuning = CrowdTuning.default
    /// The user's `promptedTopics` decide which optional parts of the answer are included
    /// (T50). Hazards are not optional: this is the answer to "what is around me", and
    /// leaving out the thing that could hurt the user would not be a preference.
    var profile = GuidanceProfile.default

    func describe(_ observation: SceneObservation) -> String {
        let grouped = detectCrowds(
            among: observation.detections.filter { $0.label.lowercased() == "person" },
            tuning: crowdTuning
        )
        let groupedIDs = grouped.groupedIDs
        let remaining = observation.prioritizedDetections.filter { !groupedIDs.contains($0.id) }

        let crowds = profile.answerIncludes(.trafficAndCrowds) ? grouped.crowds : []
        let objects = profile.answerIncludes(.structureBasics)
            ? remaining.filter { !$0.isHazard && isWorthDescribing($0) }
            : []
        let text = profile.answerIncludes(.signsAndText) ? observation.recognizedText : []

        // Hazards keep their place at the front; a crowd outranks the rest of the scene.
        let sentences = observation.elevationHazards.map(SpokenPhrasing.describe)
            + remaining.filter(\.isHazard).map(SpokenPhrasing.describe)
            + crowds.map(SpokenPhrasing.describe)
            + objects.map(SpokenPhrasing.describe)
            + text.map { "\($0.string) is visible \(direction(of: $0.boundingBox.midX))." }
        guard !sentences.isEmpty else { return "Nothing detected nearby." }
        return sentences.prefix(maxItems).joined(separator: " ")
    }

    /// From the mesh only doors (entrances) are described; windows are kept for other uses.
    private func isWorthDescribing(_ detection: Detection) -> Bool {
        detection.origin != .mesh || detection.label == "door"
    }

    /// Thirds of the upright frame.
    private func direction(of horizontalPosition: CGFloat) -> String {
        switch horizontalPosition {
        case ..<0.33: "on your left"
        case ..<0.66: "ahead"
        default: "on your right"
        }
    }
}


/// The answer-shaping preferences the description path reads. AppViewModel keeps it in step
/// with the profile, the way `AlertSettings` follows the alert filter (T50).
///
/// A holder rather than a parameter because `SceneDescribing.describeCurrentScene()` takes
/// none, and widening that protocol would be a cross-subteam contract change for a setting
/// only this side reads.
final class DescriptionSettings: Sendable {
    private let state = Mutex(GuidanceProfile.default)

    init(profile: GuidanceProfile = .default) {
        state.withLock { $0 = profile }
    }

    var profile: GuidanceProfile {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}
