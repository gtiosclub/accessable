import Foundation

/// Per-class confidence thresholds for model detections (T39); classes without one use
/// `defaultThreshold`. Labels match case-insensitively.
struct DetectionConfidencePolicy: Sendable {
    /// What the app uses: 0.6, chairs at 0.55.
    static let standard = DetectionConfidencePolicy(defaultThreshold: 0.6, thresholdsByLabel: ["chair": 0.55])
    /// RF-DETR's scores run lower than D-FINE's at the same precision. At 0.45 it matched
    /// D-FINE-at-0.6's precision (85%) on COCO street scenes and found 60% of objects instead
    /// of 48% (`Scripts/models/benchmark_detectors.py`). Vehicles get a lower bar: missing a
    /// car is worse than naming one that isn't there, and geometry still checks the path.
    static let rfdetr = DetectionConfidencePolicy(
        defaultThreshold: 0.45,
        thresholdsByLabel: ["car": 0.4, "bus": 0.4, "truck": 0.4, "motorcycle": 0.4, "bicycle": 0.4, "scooter": 0.4]
    )

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
