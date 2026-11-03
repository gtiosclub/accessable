import Foundation

enum CameraQualityFeedback: String, Equatable, Sendable {
    case tiltUp
    case tiltDown
    case tooDark
    case holdSteady

    var spokenText: String {
        switch self {
        case .tiltUp:
            "Tilt your phone upward."
        case .tiltDown:
            "Tilt your phone downward."
        case .tooDark:
            "Too dark."
        case .holdSteady:
            "Hold steady."
        }
    }
}

struct CameraQualityInput: Equatable, Sendable {
    /// Vertical component of the camera's forward direction.
    /// Negative means the camera is pointing downward.

    let forwardY: Float

    /// ARKit's estimated ambient light intensity.
    let ambientIntensity: Float?

    /// Average local contrast in the camera image.
    /// Higher values generally mean a sharper image.
    let sharpnessScore: Float?

    /// True when ARKit reports limited tracking because the phone is moving too quickly.
    let isMovingTooFast: Bool
}

struct CameraQualityEvaluator: Sendable {
    let minimumAmbientIntensity: Float
    let minimumSharpnessScore: Float
    let maximumVerticalComponent: Float

    init(
        minimumAmbientIntensity: Float = 250,
        minimumSharpnessScore: Float = 4,
        maximumVerticalComponent: Float = 0.35
    ) {
        self.minimumAmbientIntensity = minimumAmbientIntensity
        self.minimumSharpnessScore = minimumSharpnessScore
        self.maximumVerticalComponent = maximumVerticalComponent
    }

    func evaluate(_ input: CameraQualityInput) -> CameraQualityFeedback? {
        if let ambientIntensity = input.ambientIntensity,
           ambientIntensity < minimumAmbientIntensity {
            return .tooDark
        }

        if input.forwardY < -maximumVerticalComponent {
            return .tiltUp
        }

        if input.forwardY > maximumVerticalComponent {
            return .tiltDown
        }

        if input.isMovingTooFast {
            return .holdSteady
        }

        if let sharpnessScore = input.sharpnessScore,
           sharpnessScore < minimumSharpnessScore {
            return .holdSteady
        }

        return nil
    }

}
