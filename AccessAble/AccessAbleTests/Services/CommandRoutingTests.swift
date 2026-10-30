import Foundation
import Testing
@testable import AccessAble

/// Every question becomes `.ask`, and the text assistant's answers are labelled.
private struct AskEverything: CommandInterpreting {
    func interpret(_ text: String) async -> VoiceCommand { .ask(text) }
    func answer(_ question: String, context: String?) async throws -> String { "text assistant" }
}

private struct CameraScene: SceneDescribing {
    var error: (any Error)?
    func describeCurrentScene() async -> String { "" }
    func ask(_ question: String, locationContext: String?) async throws -> String {
        if let error { throw error }
        return "camera: \(question)"
    }
}

@MainActor
struct CommandRoutingTests {
    private func commands(scene: CameraScene = CameraScene()) -> CommandViewModel {
        var services = AppServices.preview
        services.commands = AskEverything()
        services.sceneDescriber = scene
        return CommandViewModel(services: services)
    }

    @Test
    func cameraQuestionsGoToAskAI() async {
        let viewModel = commands()
        await viewModel.run("What's in front of me?")
        #expect(viewModel.lastReply == "camera: What's in front of me?")
    }

    @Test
    func otherQuestionsGoToTheTextAssistant() async {
        let viewModel = commands()
        await viewModel.run("What time is it?")
        #expect(viewModel.lastReply == "text assistant")
    }

    @Test
    func cameraFailureIsExplainedNotGuessed() async {
        let viewModel = commands(scene: CameraScene(error: AskAIError.noCameraImage))
        await viewModel.run("Where is the exit?")
        #expect(viewModel.lastReply == AskAIError.noCameraImage.errorDescription)
    }

    @Test
    func simulatorSceneAnswersFromItsSample() async throws {
        let answer = try await PlaceholderSceneProvider().ask("Is there a chair?", locationContext: nil)
        #expect(answer != "Ask AI is not available yet.")
        #expect(!answer.isEmpty)
    }
}
