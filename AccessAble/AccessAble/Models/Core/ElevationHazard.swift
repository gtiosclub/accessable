import Foundation

/// How the walking surface changes. Owner: Computer Vision (1.1 / task T12).
enum ElevationHazardType: String, Codable, CaseIterable, Sendable {
    /// The ground rises — a kerb up, a step, the bottom of a stair flight.
    case stepUp
    /// The ground falls by an amount a person can step down.
    case stepDown
    /// The ground falls far enough to be a fall risk rather than a step.
    case dropOff
    /// A change we can see but cannot measure — typically a hole in depth coverage.
    case unknown
}

/// A change in the height of the walking surface, as opposed to an object sitting on it
/// (which is `GeometricObstacle`).
struct ElevationHazard: Equatable, Sendable {
    let type: ElevationHazardType
    /// Metres ahead of the user. This is the last distance the surface was confirmed at
    /// its old height — the edge itself lies between here and the next sample, so treat
    /// it as "by this far", not "exactly here".
    let distance: Float
    /// Signed height change in metres: positive rises, negative falls.
    /// Exactly 0 means the magnitude is unknown, which happens when the hazard was
    /// inferred from missing depth data rather than measured.
    let heightChange: Float

    init(type: ElevationHazardType, distance: Float, heightChange: Float) {
        self.type = type
        self.distance = distance
        self.heightChange = heightChange
    }
}
