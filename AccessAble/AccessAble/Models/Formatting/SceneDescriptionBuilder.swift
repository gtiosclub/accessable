import CoreGraphics
import Foundation

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

    func describe(_ observation: SceneObservation) -> String {
        let grouped = detectCrowds(
            among: observation.detections.filter { $0.label.lowercased() == "person" },
            tuning: crowdTuning
        )
        let groupedIDs = grouped.groupedIDs
        let remaining = observation.prioritizedDetections.filter { !groupedIDs.contains($0.id) }

        // Hazards keep their place at the front; a crowd outranks the rest of the scene.
        let sentences = observation.elevationHazards.map(SpokenPhrasing.describe)
            + remaining.filter(\.isHazard).map(SpokenPhrasing.describe)
            + grouped.crowds.map(SpokenPhrasing.describe)
            + remaining.filter { !$0.isHazard && isWorthDescribing($0) }.map(SpokenPhrasing.describe)
            + observation.recognizedText.map { "\($0.string) is visible \(direction(of: $0.boundingBox.midX))." }
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
