import Foundation
import FoundationModels

/// The deliberately small set of actions natural-language requests may trigger.
/// The model classifies a request; it never supplies executable code or arbitrary actions.
@Generable
enum AccessAbleCommandIntent {
    case describeSurroundings
    case repeatLastAnnouncement
    case pauseTrip
    case resumeTrip
    case endTrip
    case help
    case unsupported
}

struct NaturalLanguageCommandParser: Sendable {
    func parse(_ text: String) async throws -> AccessAbleCommandIntent {
        guard SystemLanguageModel.default.isAvailable else {
            throw CommandParsingError.modelUnavailable
        }
        let session = LanguageModelSession(instructions: """
            Classify the user's short command for the AccessAble mobility accessibility app.
            Choose exactly one supported intent. Describe requests map to describeSurroundings.
            Repeat requests map to repeatLastAnnouncement. Pause, resume, and stop/end navigation
            map to pauseTrip, resumeTrip, and endTrip. Requests asking what commands are available
            map to help. Anything else, ambiguous, or unrelated maps to unsupported. Do not infer
            dangerous actions. Return only the structured intent.
            """)
        let response = try await session.respond(to: String(text.prefix(500)), generating: AccessAbleCommandIntent.self)
        return response.content
    }
}

enum CommandParsingError: LocalizedError {
    case modelUnavailable
    var errorDescription: String? { "Apple Intelligence language models are unavailable on this device right now." }
}
