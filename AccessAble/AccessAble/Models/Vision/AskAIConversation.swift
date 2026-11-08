import Foundation

/// One question and its answer in an Ask AI conversation.
struct AskAITurn: Equatable, Sendable {
    let question: String
    let answer: String
}

/// What Ask AI remembers between questions, so the user can follow up ("and the door?")
/// instead of starting over. Owner: Computer Vision (1.3 / T19).
///
/// The on-device model starts a fresh session per question; the conversation reaches it as a
/// short transcript in the prompt. Only the last `maxTurns` are kept: the model's context is
/// small, and old turns describe a view the camera has left. "New conversation" clears it.
struct AskAIConversation: Sendable {
    var maxTurns = 4
    private(set) var turns: [AskAITurn] = []

    init() {}

    mutating func record(question: String, answer: String) {
        turns.append(AskAITurn(question: question, answer: answer))
        if turns.count > maxTurns { turns.removeFirst(turns.count - maxTurns) }
    }

    mutating func reset() { turns = [] }

    /// The transcript placed before the new question, or nil at the start.
    static func transcript(of turns: [AskAITurn]) -> String? {
        guard !turns.isEmpty else { return nil }
        let lines = turns.flatMap { ["User: \($0.question)", "You: \($0.answer)"] }
        return (["Earlier in this conversation (about earlier camera views):"] + lines).joined(separator: "\n")
    }

    /// Whether an answer only says the thing isn't in this picture: the cue to keep looking
    /// while the user turns. A crossing caveat is a refusal, not a "not in view".
    static func meansNotInView(_ answer: String) -> Bool {
        let text = answer.lowercased().replacingOccurrences(of: "’", with: "'")
        guard !text.contains("safe to cross") else { return false }
        // Not a bare "can't see": the model is told it can't see the picture, and may say so
        // on the way to a real answer ("I can't see the picture, but the list shows a door").
        let phrases = [
            "can't tell from this picture", "can't tell that from this picture", "cannot tell from this picture",
            "don't see", "do not see", "not in this picture", "not in the picture", "not visible",
        ]
        return phrases.contains { text.contains($0) }
    }
}
