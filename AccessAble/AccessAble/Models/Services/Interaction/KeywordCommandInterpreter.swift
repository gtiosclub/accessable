import Foundation
 
/// Owner: User Interaction (3.1). Offline keyword matching. Used when Apple Intelligence isn't available
struct KeywordCommandInterpreter: CommandInterpreting {
    func interpret(_ text: String) async -> VoiceCommand {
        let t = text.lowercased()
        func has(_ phrases: String...) -> Bool { phrases.contains { t.contains($0) } }
 
        if has("call a volunteer", "call volunteer", "call help", "call for help", "call someone", "video call", "get help") {
            return .callVolunteer
        }
        // Before "describe" / ask: "take me to…" is a place name, not a camera "take me to the door"
        // (that path uses LiveSceneView's own field, not this interpreter).
        if let place = Self.navigateDestination(in: text) {
            return .navigate(to: place)
        }
        if has("describe", "surroundings", "around me", "what do you see") { return .describeSurroundings }
        if has("where am i", "where are we") { return .whereAmI }
        if has("repeat", "say that again", "what did you say") { return .repeatLast }
        if has("resume", "continue") { return .resumeTrip }
        if has("pause", "hold on") { return .pauseTrip }
        if has("end trip", "stop trip", "cancel trip", "stop navigation", "end navigation") { return .endTrip }
        if t.hasSuffix("?") || has("what", "how", "why", "when", "who", "is there") { return .ask(text) }
        return .unknown(text)
    }

    /// Place name after "take me to", "navigate to", "go to", or "directions to"; nil if none.
    /// Keeps the caller's casing for speech ("I couldn't find Clough").
    static func navigateDestination(in text: String) -> String? {
        let lower = text.lowercased()
        let prefixes = ["take me to ", "navigate to ", "go to ", "directions to "]
        for prefix in prefixes {
            guard let range = lower.range(of: prefix) else { continue }
            let nameStart = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
            let name = String(text[nameStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return nil
    }
 
    func answer(_ question: String, context: String?) async throws -> String {
        throw CommandError.modelUnavailable(reason: "Answering questions needs Apple Intelligence.")
    }
}
