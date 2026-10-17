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
    @ObservationIgnored private var obstaclePresent = false
    @ObservationIgnored private var lastObstacleAlert: Date = .distantPast

    /// so we dont have buzzes every millisecond
    private static let obstacleAlertCooldown: TimeInterval = 1.5

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
            alertIfObstacleAppeared(in: observation)
        }
    }

    func stop() async {
        await services.scene.stop()
    }

    /// beeps when theres obstacles appeared, not when theyre already there (so we don't have a constant buzzes)
    private func alertIfObstacleAppeared(in observation: SceneObservation) {
        let detected = observation.isObstacleDetected()
        defer { obstaclePresent = detected }
        guard detected, !obstaclePresent,
              Date.now.timeIntervalSince(lastObstacleAlert) >= Self.obstacleAlertCooldown else { return }
        lastObstacleAlert = .now
        let alert = services.obstacleAlert
        Task { await alert.alert(intensity: 1.0) }
    }

    func describe() async {
        description = await services.sceneDescriber.describeCurrentScene()
    }
}
