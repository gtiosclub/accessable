import Foundation

/// Per-class confidence thresholds for model detections (T39); classes without one use
/// `defaultThreshold`. Labels match case-insensitively.
struct DetectionConfidencePolicy: Sendable {
    /// What the app uses: 0.6, chairs at 0.55.
    static let standard = DetectionConfidencePolicy(defaultThreshold: 0.6, thresholdsByLabel: ["chair": 0.55])

    let defaultThreshold: Float
    let thresholdsByLabel: [String: Float]

    init(
        defaultThreshold: Float = 0.5,
        thresholdsByLabel: [String: Float] = [:]
    ) {
        self.defaultThreshold = defaultThreshold

        self.thresholdsByLabel = thresholdsByLabel.reduce(into: [:]) { result, entry in
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
