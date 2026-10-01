import Foundation
import Observation

/// Owner: Computer Vision (1.x). Live camera guidance and "Describe my surroundings".
@MainActor
@Observable
final class SceneViewModel {
    private(set) var observation: SceneObservation = .empty
    private(set) var description: String?
    private(set) var errorMessage: String?

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
}
