import Foundation
import Observation
import UIKit

/// Owner: Computer Vision (1.1). Drives the live ARKit screen that shows what the
/// detectors are actually finding — people boxes (T14), geometric obstacles (T11), the
/// fitted floor (T10) and elevation hazards (T12).
///
/// Deliberately owns its own `ARSceneAnalyzer` instead of reading `services.scene`, so
/// turning this screen on cannot disturb the rest of the app or collide with whoever
/// wires the real provider into `AppServices` (1.4).
@MainActor
@Observable
final class LiveSceneViewModel {
    private(set) var observation: SceneObservation = .empty
    private(set) var hazards: [ElevationHazard] = []
    private(set) var errorMessage: String?
    private(set) var isRunning = false
    /// False on a device without LiDAR. People detection still works; the geometry tasks
    /// have nothing to work with.
    private(set) var isDepthAvailable = false
    /// Width / height of the upright camera image, for placing overlay boxes.
    private(set) var imageAspectRatio: CGFloat = 3.0 / 4.0
    /// Camera height above the fitted floor, in metres; nil until a floor is found.
    private(set) var cameraHeight: Float?
    /// Measured analysis rate and latency (T20); nil until a few frames have been timed.
    private(set) var performance: PerformanceMetrics?

    @ObservationIgnored let analyzer: ARSceneAnalyzer

    init(services: AppServices) {
        analyzer = ARSceneAnalyzer(
            sessionManager: ARSessionManager(),
            performance: services.performance,
            announcements: services.announcements
        )
    }

    func start() async {
        analyzer.setInterfaceOrientation(.portrait)
        do {
            try await analyzer.start()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        isRunning = true
        isDepthAvailable = analyzer.sessionManager.isDepthSupported

        for await observation in analyzer.observations() {
            let diagnostics = analyzer.perception.diagnostics
            self.observation = observation
            hazards = observation.elevationHazards
            cameraHeight = diagnostics.cameraHeight
            performance = diagnostics.performance
            imageAspectRatio = CGFloat(diagnostics.uprightAspectRatio)
        }
    }

    func stop() async {
        isRunning = false
        await analyzer.stop()
    }

    var people: [Detection] {
        observation.detections.filter { $0.label == "person" }
    }

    /// Everything the geometry found in the walking corridor, labelled or not.
    var obstacles: [Detection] {
        observation.detections.filter { $0.origin == .geometric }
    }

    var floorDescription: String {
        guard isDepthAvailable else { return "No depth sensor on this device" }
        guard let height = cameraHeight else { return "Looking for the ground…" }
        // Held normally this should read roughly 1.1 to 1.5 m. A wildly different number
        // means the floor fit latched onto something that is not the floor.
        return String(format: "Floor found, camera %.2f m above it", height)
    }

    var performanceDescription: String? {
        performance.map {
            String(format: "%.0f fps, %.0f ms (p95 %.0f ms)", $0.averageFPS, $0.averageLatencyMilliseconds, $0.p95LatencyMilliseconds)
        }
    }

    var countsDescription: String {
        "\(people.count) person(s), \(obstacles.count) obstacle(s) in your path"
    }

    /// What VoiceOver reads for the readout; the overlay boxes themselves are purely visual.
    var spokenSummary: String {
        SceneDescriptionBuilder().describe(observation)
    }

    /// "Drop-off at 2.0 m, -0.18 m". A heightChange of 0 means the magnitude was never
    /// measured (the surface simply stopped returning depth), so it is left off.
    func hazardLine(_ hazard: ElevationHazard) -> String {
        let head = String(format: "%@ at %.1f m", SpokenPhrasing.name(of: hazard.type), hazard.distance)
        guard hazard.heightChange != 0 else { return head }
        return head + String(format: ", %+.2f m", hazard.heightChange)
    }
}
