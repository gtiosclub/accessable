import Foundation

/// What the steering tone should do, from the current path warning. Owner: Computer Vision (1.1).
///
/// After Google's Project Guideline: instead of more words, a short beep from the side the
/// user should move towards, faster the farther they have to go and higher the closer the
/// obstacle is. It stops when they are on the clear line, which is the moment "Straight ahead
/// now" is spoken. `SteeringTones` plays it.
struct SteeringCue: Equatable, Sendable {
    /// Where the beep comes from, -1 (hard left) to 1 (hard right).
    var side: Float
    /// 0 for far away to 1 for at the stop distance; raises the pitch.
    var urgency: Float

    /// The sidestep at which the beep is hard over to one side, in metres.
    static let fullSidestep: Float = 1.5

    /// Seconds between beeps: about 0.7 s for a small correction down to 0.18 s for a big one.
    var interval: TimeInterval { TimeInterval(0.7 - 0.52 * min(abs(side), 1)) }

    /// nil when there is nothing to steer around, or no way round to point to.
    init?(warning: PathWarning?, stopDistance: Float = 1.2, warningDistance: Float = 2.5) {
        guard let warning, let turn = warning.side else { return nil }
        let sign: Float = turn == .left ? -1 : 1
        // A turn with no measured gap is a full turn; a sidestep is as far as it measured.
        let amount = warning.offset.map { min(abs($0) / Self.fullSidestep, 1) } ?? 1
        side = sign * max(amount, 0.25)
        let distance = Float(warning.distance ?? Double(warningDistance))
        let span = max(warningDistance - stopDistance, 0.1)
        urgency = min(max((warningDistance - distance) / span, 0), 1)
    }

    init(side: Float, urgency: Float) {
        self.side = side
        self.urgency = urgency
    }
}
