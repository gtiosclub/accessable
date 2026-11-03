import Foundation

/// T38: decides whether a spoken or typed question is about what the camera sees, so it
/// goes to Ask AI with a live camera frame instead of the text-only assistant. Word lists
/// rather than a model: it runs before every question and has to be instant and offline.
enum VisualQuestion {
    /// True when answering needs the camera: what's around, where something is, what a
    /// sign says, what colour something is. Map and general-knowledge questions are not.
    static func needsCamera(_ question: String) -> Bool {
        let text = " " + question.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .joined(separator: " ") + " "
        func has(_ phrases: [String]) -> Bool { phrases.contains { text.contains(" \($0) ") } }

        // "Where is the nearest pharmacy?" is a map question, not a camera one.
        if has(notVisual) { return false }
        return has(visualPhrases) || has(visualWords)
    }

    private static let notVisual = [
        "nearest", "closest", "directions", "navigate", "route", "how do i get", "how far is it to",
        "weather", "time is it", "what time", "what day", "date today",
    ]

    private static let visualPhrases = [
        "in front of me", "ahead of me", "around me", "next to me", "near me", "behind me",
        "my left", "my right", "on the left", "on the right",
        "do you see", "can you see", "what do you see", "what can you see", "is there", "are there",
        "what is that", "what's that", "what is this", "what's this", "what am i looking at",
        "where is", "where's", "where are", "which way", "which door", "how far", "how many",
        "look like", "looks like", "what colour", "what color", "what does it say", "what does the sign say",
        "read the", "read it", "read this", "read that",
    ]

    private static let visualWords = [
        "sign", "signs", "door", "doors", "exit", "entrance", "room", "stairs", "step", "steps", "kerb", "curb",
        "crosswalk", "crossing", "obstacle", "obstacles", "someone", "anyone", "person", "people",
        "chair", "bench", "table", "car", "bike", "bicycle", "traffic light", "elevator", "lift",
        "colour", "color", "nearby",
    ]
}
