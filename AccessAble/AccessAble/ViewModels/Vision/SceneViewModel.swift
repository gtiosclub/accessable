import Foundation
import Observation
import UIKit

/// Owner: Computer Vision (1.x). Live camera guidance and "Describe my surroundings".
@MainActor
@Observable
final class SceneViewModel {
    private(set) var observation: SceneObservation = .empty
    private(set) var description: String?
    private(set) var errorMessage: String?
    /// Ask AI (T19): the latest answer, or why there isn't one. Cleared when a new question starts.
    private(set) var answer: String?
    private(set) var askError: String?
    private(set) var isAsking = false
    /// The camera image the latest answer was based on, when the service can provide it.
    private(set) var askedImage: UIImage?

    @ObservationIgnored private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func start() async {
        do {
            try await services.scene.start()
        } catch {
            errorMessage = "Camera guidance is unavailable."
            return
        }
        for await observation in services.scene.observations() {
            self.observation = observation
        }
    }

    func stop() async {
        await services.scene.stop()
    }

    func describe() async {
        description = await services.sceneDescriber.describeCurrentScene()
    }

    /// Asks about the next camera frame. One question at a time; a second tap while one is
    /// running does nothing.
    func ask(_ question: String) async {
        guard !isAsking else { return }
        isAsking = true
        answer = nil
        askError = nil
        askedImage = nil
        defer { isAsking = false }
        do {
            answer = try await services.sceneDescriber.ask(question, locationContext: nil)
        } catch {
            askError = error.localizedDescription
        }
        // Also after a failure: a model error still has the image that was captured.
        askedImage = (services.sceneDescriber as? any AskedImageProviding)?
            .lastAskedImage.flatMap { UIImage(data: $0) }
    }
}
