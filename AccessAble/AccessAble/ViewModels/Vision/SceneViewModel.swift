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
    /// Progress of "Take me to…"; nil without a request, or where the service cannot navigate.
    private(set) var navigation: NavigationStatus?

    /// False where the scene service has no camera (previews, the Simulator).
    var canNavigate: Bool { services.scene is any SceneNavigating }

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
            navigation = (services.scene as? any SceneNavigating)?.navigationStatus
            alertIfObstacleAppeared(in: observation)
        }
    }

    /// Starts steering towards `query`; an empty query cancels.
    func navigate(to query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        (services.scene as? any SceneNavigating)?.navigate(to: trimmed.isEmpty ? nil : trimmed)
        if trimmed.isEmpty { navigation = nil }
    }

    var isNavigating: Bool {
        switch navigation?.phase {
        case .scanning, .guiding: true
        default: false
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
