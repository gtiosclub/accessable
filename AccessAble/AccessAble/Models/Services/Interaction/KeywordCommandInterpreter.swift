import Foundation
 
/// Owner: User Interaction (3.1). Offline keyword matching. Used when Apple Intelligence isn't available
struct KeywordCommandInterpreter: CommandInterpreting {
    func interpret(_ text: String) async -> VoiceCommand {
        let t = text.lowercased()
        func has(_ phrases: String...) -> Bool { phrases.contains { t.contains($0) } }
 
        if has("call a volunteer", "call volunteer", "call help", "call for help", "call someone", "video call", "get help") {
            return .callVolunteer
        }
        // Before "describe" / ask, but only at the start: "how do I go to…" stays a question. Camera
        // "take me to the door" never comes here (LiveSceneView has its own field).
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

    /// Place name after "take me to", "navigate to", "go to", or "directions to" at the start (after an
    /// optional "please", "hey", "can you"…), without trailing punctuation or "please"; "home" for
    /// "take me home" / "go home"; nil otherwise. Keeps the caller's casing for speech ("I couldn't find Clough").
    static func navigateDestination(in text: String) -> String? {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let end = leadingFillers.lazy.compactMap({ wordEnd(of: $0, atStartOf: rest) }).first {
            rest = rest[end...].drop { $0 == "," || $0.isWhitespace }
        }
        if homePhrases.contains(where: { trimmedEnd(rest).caseInsensitiveCompare($0) == .orderedSame }) {
            return "home"
        }
        guard let prefix = navigatePrefixes.lazy.compactMap({
            rest.range(of: $0, options: [.caseInsensitive, .anchored])
        }).first else { return nil }
        let name = trimmedEnd(rest[prefix.upperBound...])
        guard !name.isEmpty, !appScreens.contains(name.lowercased()) else { return nil }
        return name
    }

    private static let leadingFillers = ["please", "hey", "okay", "ok", "can you", "could you"]
    private static let navigatePrefixes = ["take me to ", "navigate to ", "go to ", "directions to "]
    private static let homePhrases = ["take me home", "go home", "navigate home", "directions home"]
    /// Screens of the app, not places to walk to.
    private static let appScreens = ["settings", "the settings", "the home screen", "home screen"]

    /// Where `word` ends when `text` starts with it as a whole word.
    private static func wordEnd(of word: String, atStartOf text: Substring) -> Substring.Index? {
        guard let range = text.range(of: word, options: [.caseInsensitive, .anchored]),
              range.upperBound == text.endIndex || !text[range.upperBound].isLetter else { return nil }
        return range.upperBound
    }

    /// Without trailing punctuation, spaces, or a closing "please".
    private static func trimmedEnd(_ text: Substring) -> String {
        var name = text
        while true {
            let before = name
            name = Substring(name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))
            if let range = name.range(of: " please", options: [.caseInsensitive, .anchored, .backwards]) {
                name = name[..<range.lowerBound]
            }
            if name == before { return String(name) }
        }
    }
 
    func answer(_ question: String, context: String?) async throws -> String {
        throw CommandError.modelUnavailable(reason: "Answering questions needs Apple Intelligence.")
    }
}
