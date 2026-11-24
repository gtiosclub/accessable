import Foundation

/// A ringing offer only; tokens still come from CallSignaling.accept, never from a listener.
struct IncomingCall: Identifiable, Equatable, Sendable {
    let id: String
    let callerFirstName: String
    let ringingSince: Date

    static let displayLifetime: TimeInterval = 30

    static func firstName(from name: String) -> String {
        // Match Firestore's RE2 \\s character set, including tabs/newlines.
        name.components(separatedBy: CharacterSet(charactersIn: " \t\r\n\u{000B}\u{000C}"))
            .first(where: { !$0.isEmpty }) ?? "Caller"
    }

    func remainingTime(at now: Date) -> TimeInterval {
        min(Self.displayLifetime, max(0, ringingSince.addingTimeInterval(Self.displayLifetime).timeIntervalSince(now)))
    }
}
