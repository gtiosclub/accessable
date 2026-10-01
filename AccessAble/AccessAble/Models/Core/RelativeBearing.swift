import Foundation

/// Direction of something relative to where the user (or camera) is facing.
/// 0° is straight ahead, negative is to the left, positive is to the right, ±180° is behind.
struct RelativeBearing: Codable, Hashable, Sendable {
    /// Always normalized to -180...180.
    let degrees: Double

    init(degrees: Double) {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        self.degrees = d
    }

    static let ahead = RelativeBearing(degrees: 0)

    enum Side: String, Sendable {
        case ahead, slightlyLeft, left, slightlyRight, right, behind
    }

    var side: Side {
        switch degrees {
        case -15...15: .ahead
        case -45 ..< -15: .slightlyLeft
        case 15 ..< 45: .slightlyRight
        case -135 ..< -45: .left
        case 45 ..< 135: .right
        default: .behind
        }
    }

    /// 12 = ahead, 3 = right, 9 = left, 6 = behind.
    var clockPosition: Int {
        let hour = (Int((degrees / 30).rounded()) + 12) % 12
        return hour == 0 ? 12 : hour
    }

    /// Bearing to a target given the user's heading and the absolute bearing to the target (both in degrees from true north).
    static func from(heading: Double, toAbsoluteBearing target: Double) -> RelativeBearing {
        RelativeBearing(degrees: target - heading)
    }
}
