import CoreGraphics
import Foundation

/// One detection whose identity has been maintained across camera frames.
///
/// Bounding boxes and velocity are in normalized, upright image coordinates. Velocity is
/// measured in normalized image units per second.
struct TrackedObject: Equatable, Sendable {
    let id: UUID
    var label: String
    var boundingBox: CGRect
    var confidence: Float
    var imageVelocity: CGVector
    var lastSeen: Date

    init(
        id: UUID = UUID(),
        label: String,
        boundingBox: CGRect,
        confidence: Float,
        imageVelocity: CGVector = .zero,
        lastSeen: Date
    ) {
        self.id = id
        self.label = label
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.imageVelocity = imageVelocity
        self.lastSeen = lastSeen
    }
}
