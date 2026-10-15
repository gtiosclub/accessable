import CoreGraphics
import Foundation

/// The instant, offline answer to "Describe my surroundings" (Tier A).
/// Owner: Computer Vision (1.3 / task T18).
///
/// Surface hazards come first, then detections hazards-first and nearest-first, then any
/// text in view. Only the first `maxItems` are spoken: a scene can hold dozens of things,
/// and the user needs the few that matter, not an inventory.
struct SceneDescriptionBuilder: Sendable {
    var maxItems = 4

    func describe(_ observation: SceneObservation) -> String {
        let sentences = observation.elevationHazards.map(SpokenPhrasing.describe)
            + observation.prioritizedDetections.map(SpokenPhrasing.describe)
            + observation.recognizedText.map { "\($0.string) is visible \(direction(of: $0.boundingBox.midX))." }
        guard !sentences.isEmpty else { return "Nothing detected nearby." }
        return sentences.prefix(maxItems).joined(separator: " ")
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
