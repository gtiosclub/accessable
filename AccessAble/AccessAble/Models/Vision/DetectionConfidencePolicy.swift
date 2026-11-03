import Foundation

struct DetectionConfidencePolicy: Sendable {
    let defaultThreshold: Float
    let thresholdsByLabel: [String: Float]
    
    init(
        defaultThreshold: Float = 0.5,
        thresholdsByLabel: [String: Float] = [:]
    ) {
        self.defaultThreshold = defaultThreshold
        
        self.thresholdsByLabel = thresholdsByLabel.reduce(into: [:]) {
            result, entry in
            result[entry.key.lowercased()] = entry.value
        }
    }
    
    func threshold(for label: String) -> Float {
        thresholdsByLabel[label.lowercased()] ?? defaultThreshold
    }
    
    func accepts(label: String, confidence: Float) -> Bool {
        confidence >= threshold(for: label)
    }
}
