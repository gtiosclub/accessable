import Foundation
import Synchronization
import Testing
@testable import SceneGeometry

/// Records the conversation it was given and answers from a script.
private final class ConversationRecorder: AskAIResponder, Sendable {
    let seen = Mutex<[[AskAITurn]]>([])
    let reply: String
    init(reply: String) { self.reply = reply }

    func answer(_ question: String, facts: ImageFacts) async throws -> String { reply }

    func answer(_ question: String, facts: ImageFacts, conversation: [AskAITurn]) async throws -> String {
        seen.withLock { $0.append(conversation) }
        return reply
    }
}

@Suite("Ask AI as a conversation")
struct AskAIConversationTests {
    @Test("keeps the last few turns, and starts over on reset")
    func memory() {
        var conversation = AskAIConversation()
        for index in 1 ... 6 {
            conversation.record(question: "Q\(index)", answer: "A\(index)")
        }
        #expect(conversation.turns.map(\.question) == ["Q3", "Q4", "Q5", "Q6"])
        conversation.reset()
        #expect(conversation.turns.isEmpty)
    }

    @Test("the transcript goes before the new question in the model's prompt")
    func prompt() {
        let turns = [AskAITurn(question: "Where is room 0266?", answer: "I can't tell from this picture.")]
        let prompt = AskAIRules.prompt(question: "What about now?", facts: ImageFacts(), conversation: turns)
        let transcript = prompt.range(of: "User: Where is room 0266?")
        let question = prompt.range(of: "What about now?")
        #expect(transcript != nil && question != nil)
        #expect(transcript!.lowerBound < question!.lowerBound)
        #expect(AskAIRules.prompt(question: "Hi", facts: ImageFacts()).contains("Earlier in this conversation") == false)
    }

    @Test("the rules layer passes the conversation on to the model")
    func passesThrough() async throws {
        let model = ConversationRecorder(reply: "Room 0266 is on your left.")
        let responder = RuledAskAIResponder(model: model)
        let turns = [AskAITurn(question: "Where is room 0266?", answer: "Turn slowly.")]
        _ = try await responder.answer("And now?", facts: ImageFacts(), conversation: turns)
        #expect(model.seen.withLock { $0 } == [turns])
    }

    @Test("'not in this picture' answers start the keep-looking loop; real answers and refusals don't")
    func notInView() {
        #expect(AskAIConversation.meansNotInView("I can't tell from this picture."))
        #expect(AskAIConversation.meansNotInView("I can’t tell that from this picture. I can see a chair."))
        #expect(AskAIConversation.meansNotInView("I don't see room 0266 here."))
        #expect(!AskAIConversation.meansNotInView("Room 0266 is on your left, about 3 metres away."))
        #expect(!AskAIConversation.meansNotInView("I can't see the picture, but the list shows a door on your left."))
        #expect(!AskAIConversation.meansNotInView("I can't tell if it's safe to cross. I can't tell from this picture."))
    }
}
