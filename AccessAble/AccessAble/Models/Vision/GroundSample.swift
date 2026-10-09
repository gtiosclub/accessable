import Foundation

/// One height reading of the walking surface ahead of the user, sampled along the
/// direction of travel. Owner: Computer Vision (1.1 / task T12).
struct GroundSample: Sendable {
    /// Metres ahead of the user, measured along the ground.
    let forwardDistance: Float
    /// Metres above the reference floor plane. Negative is below it.
    let height: Float

    init(forwardDistance: Float, height: Float) {
        self.forwardDistance = forwardDistance
        self.height = height
    }
}
