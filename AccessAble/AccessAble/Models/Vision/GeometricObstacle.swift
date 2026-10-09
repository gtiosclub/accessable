import Foundation
import simd

/// Something standing up off the floor, found by geometry alone — no object-recognition
/// label involved, so it catches the things a model has never seen.
/// Owner: Computer Vision (1.1 / task T11).
struct GeometricObstacle: Identifiable, Sendable {
    let id: UUID
    /// Centroid of the supporting points, in the input cloud's coordinate space (metres).
    let center: SIMD3<Float>
    /// Straight-line distance in metres from `corridor.origin` to the nearest supporting
    /// point. This is the distance to announce — not the distance along the path.
    let nearestDistance: Float
    /// Extent along the corridor's lateral axis, in metres. Corridor-relative, not a
    /// world axis-aligned box, so it answers "how much of my way does this block".
    let width: Float
    /// Height above the floor plane of the highest supporting point, in metres. The top
    /// of the object, not the vertical extent of the points — an overhanging sign reports
    /// the height you would hit it at.
    let height: Float
    /// True when any supporting point falls inside the corridor. False obstacles are
    /// still returned, so callers can keep tracking something about to cut in.
    let intersectsWalkingCorridor: Bool

    init(
        id: UUID = UUID(),
        center: SIMD3<Float>,
        nearestDistance: Float,
        width: Float,
        height: Float,
        intersectsWalkingCorridor: Bool
    ) {
        self.id = id
        self.center = center
        self.nearestDistance = nearestDistance
        self.width = width
        self.height = height
        self.intersectsWalkingCorridor = intersectsWalkingCorridor
    }
}
