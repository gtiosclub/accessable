import Foundation

/// One text message in a caller–volunteer chat (CHAT-1).
struct ChatMessage: Identifiable, Hashable, Sendable {
    /// The most a message may hold. Must match firestore.rules.
    static let maxLength = 1000

    let id: String
    var text: String
    var senderID: String
    /// Server time; a message still on its way has the phone's estimate.
    var sentAt: Date

    init(id: String = UUID().uuidString, text: String, senderID: String, sentAt: Date = Date()) {
        self.id = id
        self.text = text
        self.senderID = senderID
        self.sentAt = sentAt
    }

    /// The text as it would be sent, or nil when it is empty or too long.
    static func sendable(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= maxLength else { return nil }
        return trimmed
    }
}

/// A volunteer's view of one chat in their inbox.
struct ChatThread: Identifiable, Hashable, Sendable {
    let id: String
    var callerFirstName: String
    var updatedAt: Date
}

/// A chat's id names both parties, caller first, so the rules know who may read it before it exists.
enum ChatID {
    static func make(callerID: String, volunteerID: String) -> String {
        "\(callerID)_\(volunteerID)"
    }

    static func parties(of chatID: String) -> (caller: String, volunteer: String)? {
        let parts = chatID.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }
}

enum ChatError: Error, LocalizedError, Equatable, Sendable {
    case signedOut
    case invalidMessage
    /// The rules refused: a block, or the other person can't receive messages.
    case notAllowed
    case volunteerUnavailable
    case offline
    case unavailable

    var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in to send messages."
        case .invalidMessage: "Messages can be up to \(ChatMessage.maxLength) characters."
        case .notAllowed: "This message couldn't be sent to this person."
        case .volunteerUnavailable: "This volunteer can't receive messages right now."
        case .offline: "You're offline. Your message wasn't sent."
        case .unavailable: "Messages aren't available right now. Please try again."
        }
    }
}
