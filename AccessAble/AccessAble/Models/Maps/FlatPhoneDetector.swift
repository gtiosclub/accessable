import Foundation

/// Screen-up, roughly level: gravity.z below about -0.9. Hysteresis keeps it from flickering.
struct FlatPhoneDetector: Sendable {
    private(set) var isFlat = false

    private static let enterThreshold = -0.9
    private static let exitThreshold = -0.85

    mutating func update(gravityZ: Double) -> Bool {
        guard gravityZ.isFinite else { return isFlat }
        if isFlat {
            if gravityZ > Self.exitThreshold { isFlat = false }
        } else if gravityZ < Self.enterThreshold {
            isFlat = true
        }
        return isFlat
    }
}