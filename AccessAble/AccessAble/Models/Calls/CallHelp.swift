import Foundation

/// Someone the signed-in user has starred (SAVE-1).
struct SavedPerson: Identifiable, Hashable, Sendable {
    /// The other person's user id.
    let id: String
    var name: String
    /// They starred the signed-in user too.
    var isMutual: Bool
}

/// A finished call that was answered (HISTORY-1).
struct PastCall: Identifiable, Hashable, Sendable {
    let id: String
    /// The other person: the volunteer for a caller, the caller for a volunteer.
    let otherID: String
    /// Known for a volunteer's history; a caller's comes from the volunteer directory.
    var otherName: String?
    let startedAt: Date
    let duration: TimeInterval

    /// "11/3/2026 · 56 minutes"
    var summary: String {
        let date = startedAt.formatted(date: .numeric, time: .omitted)
        let minutes = max(1, Int((duration / 60).rounded()))
        return "\(date) · \(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    /// The same, spelled out for VoiceOver.
    var spokenSummary: String {
        let date = startedAt.formatted(date: .long, time: .shortened)
        let minutes = max(1, Int((duration / 60).rounded()))
        return "\(date), \(minutes) minute\(minutes == 1 ? "" : "s")"
    }
}

/// The id of a save or chat that pairs two people, in the order the rules expect.
enum PairID {
    static func make(_ first: String, _ second: String) -> String { "\(first)_\(second)" }
}
