import CoreGraphics
import Foundation

enum PointIdentificationKind: Equatable, Sendable {
    case text
    case object
}

struct PointIdentification: Equatable, Sendable {
    let text: String
    let kind: PointIdentificationKind
}

/// Point-and-identify (T43): the text, or failing that the object, nearest the middle of
/// the frame. Text wins because a sign or label the user aims at is usually what they want
/// read; among objects, recognized ones beat mesh features, which beat bare geometry.
struct PointIdentifier: Sendable {
    let maximumCenterDistance: CGFloat

    init(maximumCenterDistance: CGFloat = 0.22) {
        self.maximumCenterDistance = maximumCenterDistance
    }

    func identify(in observation: SceneObservation) -> PointIdentification? {
        if let recognizedText = bestText(in: observation.recognizedText) {
            return PointIdentification(
                text: recognizedText.string.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: .text
            )
        }

        if let detection = bestDetection(in: observation.detections) {
            return PointIdentification(
                text: detection.label,
                kind: .object
            )
        }

        return nil
    }

    /// What to say for `identify(in:)`: the text as read, or the object with its direction
    /// and distance ("Chair 2 metres ahead."), which is what someone pointing needs next.
    func spokenIdentification(in observation: SceneObservation) -> String? {
        if let text = bestText(in: observation.recognizedText) {
            return text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return bestDetection(in: observation.detections).map(SpokenPhrasing.describe)
    }

    private func bestText(in items: [RecognizedText]) -> RecognizedText? {
        items
            .filter {
                let text = $0.string.trimmingCharacters(in: .whitespacesAndNewlines)
                let area = $0.boundingBox.width * $0.boundingBox.height

                return isUsefulText(text) &&
                    $0.confidence >= 0.5 &&
                    area >= 0.001 &&
                    isNearCenter($0.boundingBox)
            }
            .sorted(by: isBetterText)
            .first
    }

    private func isUsefulText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let alphanumericCount = trimmed.filter {
            $0.isLetter || $0.isNumber
        }.count

        return alphanumericCount >= 2
    }

    private func bestDetection(in detections: [Detection]) -> Detection? {
        detections
            .filter {
                !$0.label.isEmpty && isNearCenter($0.boundingBox)
            }
            .sorted(by: isBetterDetection)
            .first
    }

    private func isNearCenter(_ box: CGRect) -> Bool {
        let center = CGPoint(x: 0.5, y: 0.5)

        if box.contains(center) {
            return true
        }

        return centerDistanceSquared(box) <= maximumCenterDistance * maximumCenterDistance
    }

    private func centerDistanceSquared(_ box: CGRect) -> CGFloat {
        let dx = box.midX - 0.5
        let dy = box.midY - 0.5
        return dx * dx + dy * dy
    }

    private func isBetterText(_ lhs: RecognizedText, _ rhs: RecognizedText) -> Bool {
        let center = CGPoint(x: 0.5, y: 0.5)
        let lhsContainsCenter = lhs.boundingBox.contains(center)
        let rhsContainsCenter = rhs.boundingBox.contains(center)

        if lhsContainsCenter != rhsContainsCenter {
            return lhsContainsCenter
        }

        let lhsDistance = centerDistanceSquared(lhs.boundingBox)
        let rhsDistance = centerDistanceSquared(rhs.boundingBox)

        if lhsDistance != rhsDistance {
            return lhsDistance < rhsDistance
        }

        return lhs.confidence > rhs.confidence
    }

    private func isBetterDetection(_ lhs: Detection, _ rhs: Detection) -> Bool {
        let center = CGPoint(x: 0.5, y: 0.5)

        let lhsRank = originRank(lhs.origin)
        let rhsRank = originRank(rhs.origin)

        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }

        let lhsContainsCenter = lhs.boundingBox.contains(center)
        let rhsContainsCenter = rhs.boundingBox.contains(center)

        if lhsContainsCenter != rhsContainsCenter {
            return lhsContainsCenter
        }

        let lhsDistance = centerDistanceSquared(lhs.boundingBox)
        let rhsDistance = centerDistanceSquared(rhs.boundingBox)

        if lhsDistance != rhsDistance {
            return lhsDistance < rhsDistance
        }

        return lhs.confidence > rhs.confidence
    }

    private func originRank(_ origin: Detection.Origin) -> Int {
        switch origin {
        case .model:
            0
        case .mesh:
            1
        case .geometric:
            2
        }
    }
}
