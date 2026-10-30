import Testing
@testable import SceneGeometry

@Suite("T38 — which questions need the camera")
struct VisualQuestionTests {
    @Test(arguments: [
        "What's in front of me?",
        "Where is room 210?",
        "Where's the exit?",
        "Is there a chair nearby?",
        "Which door is the exit?",
        "What does the sign say?",
        "What colour is the bench?",
        "Can you read this?",
        "Is anyone on my left?",
        "How far is the crosswalk?",
        "What am I looking at",
    ])
    func cameraQuestions(_ question: String) {
        #expect(VisualQuestion.needsCamera(question))
    }

    @Test(arguments: [
        "Where is the nearest pharmacy?",
        "What time is it?",
        "What's the weather like?",
        "How do I get to the library?",
        "Who wrote Hamlet?",
        "Why is the sky blue?",
    ])
    func otherQuestions(_ question: String) {
        #expect(!VisualQuestion.needsCamera(question))
    }
}
