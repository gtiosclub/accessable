import Foundation
import FoundationModels
import os
 
private let log = Logger(subsystem: "AccessAble", category: "Commands")
 
/// Owner: User Interaction (3.1). Uses Apple's on-device model (Foundation Models) to turn free text into a
/// `VoiceCommand`, and to answer short questions. Falls back to keyword matching when the model isn't available.
/// A fresh session per request keeps calls independent (no growing context, no "already responding" errors).
struct FoundationModelCommandInterpreter: CommandInterpreting {
    private let fallback = KeywordCommandInterpreter()
 
    private static let commandInstructions = """
        You turn what a blind or low-vision pedestrian says to a walking-guidance app into exactly one action.
        Choose the action that best matches what they want. If they ask a general question, choose askQuestion \
        and put the question in detail. If nothing fits, choose unknown.
        """
 
    private static let answerInstructions = """
        You are the assistant inside a walking-guidance app for blind and low-vision people.
        Your reply is read aloud: answer in one or two short sentences of plain text, with no lists or formatting.
        Never tell the user it is safe to cross a street. If you don't know, say so.
        """
 
    func interpret(_ text: String) async -> VoiceCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown(text) }
        guard SystemLanguageModel.default.isAvailable else { return await fallback.interpret(trimmed) }
        do {
            let session = LanguageModelSession(instructions: Self.commandInstructions)
            let response = try await session.respond(to: trimmed, generating: GeneratedCommand.self)
            return response.content.voiceCommand(original: trimmed)
        } catch {
            log.error("interpret failed: \(error.localizedDescription)")
            return await fallback.interpret(trimmed)
        }
    }
 
    func answer(_ question: String, context: String?) async throws -> String {
        if let reason = Self.unavailableReason() {
            throw CommandError.modelUnavailable(reason: reason)
        }
        var prompt = question
        if let context { prompt += "\n\nWhere the user is: \(context)" }
        do {
            let session = LanguageModelSession(instructions: Self.answerInstructions)
            return try await session.respond(to: prompt).content
        } catch let error as LanguageModelSession.GenerationError {
            log.error("answer failed: \(error.localizedDescription)")
            if case .guardrailViolation = error { throw CommandError.refused }
            throw CommandError.failed
        }
    }
 
    /// Spoken explanation when the on-device model can't be used, or nil when it can.
    private static func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            nil
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in Settings to ask questions."
        case .unavailable(.modelNotReady):
            "The on-device model is still getting ready. Try again in a few minutes."
        case .unavailable(.deviceNotEligible):
            "This iPhone can't run the on-device model."
        default:
            "Answering questions isn't available right now."
        }
    }
}
 
// MARK: - Guided generation
 
@Generable
struct GeneratedCommand {
    @Guide(description: "The single action the user wants.")
    var action: GeneratedAction
 
    @Guide(description: "For askQuestion, the user's question as a complete sentence. Otherwise an empty string.")
    var detail: String
}
 
@Generable
enum GeneratedAction {
    case describeSurroundings
    case whereAmI
    case repeatLast
    case pauseTrip
    case resumeTrip
    case endTrip
    case askQuestion
    case unknown
}
 
extension GeneratedCommand {
    func voiceCommand(original: String) -> VoiceCommand {
        switch action {
        case .describeSurroundings: .describeSurroundings
        case .whereAmI: .whereAmI
        case .repeatLast: .repeatLast
        case .pauseTrip: .pauseTrip
        case .resumeTrip: .resumeTrip
        case .endTrip: .endTrip
        case .askQuestion: .ask(detail.isEmpty ? original : detail)
        case .unknown: .unknown(original)
        }
    }
}
