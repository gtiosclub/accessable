import Foundation
 
/// Owner: User Interaction (3.1). Offline keyword matching. Used when Apple Intelligence isn't available
struct KeywordCommandInterpreter: CommandInterpreting {
    func interpret(_ text: String) async -> VoiceCommand {
        let t = text.lowercased()
        func has(_ phrases: String...) -> Bool { phrases.contains { t.contains($0) } }
 
        if has("describe", "surroundings", "around me", "what do you see") { return .describeSurroundings }
        if has("where am i", "where are we") { return .whereAmI }
        if has("repeat", "say that again", "what did you say") { return .repeatLast }
        if has("resume", "continue") { return .resumeTrip }
        if has("pause", "hold on") { return .pauseTrip }
        if has("end trip", "stop trip", "cancel trip", "stop navigation", "end navigation") { return .endTrip }
        if t.hasSuffix("?") || has("what", "how", "why", "when", "who", "is there") { return .ask(text) }
        return .unknown(text)
    }
 
    func answer(_ question: String, context: String?) async throws -> String {
        throw CommandError.modelUnavailable(reason: "Answering questions needs Apple Intelligence.")
    }
}
