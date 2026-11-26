import Foundation

/// A ringing offer only; tokens still come from CallSignaling.accept, never from a listener.
struct IncomingCall: Identifiable, Equatable, Sendable {
    let id: String
    let callerFirstName: String
    /// When the ring started, on this phone's clock.
    let ringingSince: Date

    static let displayLifetime: TimeInterval = 30

    static func firstName(from name: String) -> String {
        // Exactly Firestore's RE2 \\s ([\t\n\f\r ]), which the rules split on. RE2's \\s has no
        // vertical tab, so splitting on it here would give a name the rules refuse.
        name.components(separatedBy: CharacterSet(charactersIn: " \t\r\n\u{000C}"))
            .first(where: { !$0.isEmpty }) ?? "Caller"
    }

    func remainingTime(at now: Date) -> TimeInterval {
        min(Self.displayLifetime, max(0, ringingSince.addingTimeInterval(Self.displayLifetime).timeIntervalSince(now)))
    }
}
