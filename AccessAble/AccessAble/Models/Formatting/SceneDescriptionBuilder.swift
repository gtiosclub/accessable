import CoreGraphics
import Foundation

struct SceneDescriptionBuilder: Sendable {
    func describe(_ observation: SceneObservation) -> String {
        var sentences = observation.prioritizedDetections.map { detection in
            SpokenPhrasing.describe(detection)
        }
        
        let textSentences = observation.recognizedText.map { recognizedText in
            let direction = horizontalDirection(
                for: recognizedText.boundingBox.midX
            )
            
            return "\(recognizedText.string) is visible \(direction)."
        }
        
        sentences.append(contentsOf: textSentences)
        
        return sentences.joined(separator: " ")
    }
    
    private func horizontalDirection(for position: CGFloat) -> String {
        if position < 0.33 {
            return "on your left"
        } else if position < 0.66 {
            return "ahead"
        } else {
            return "on your right"
        }
    }
}
