import Foundation
import Observation
import UIKit

/// Owner: Computer Vision (1.1). Drives the live ARKit debug screen that shows what the
/// pipeline is actually finding — recognized objects and people (T13, T14), geometric
/// obstacles (T11), the fitted floor (T10), elevation hazards (T12) and measured
/// performance (T20).
///
/// It runs the app's shared `ARSceneAnalyzer` (`services.scene`), so what it shows is what
/// guidance uses. Where ARKit is unavailable that is a placeholder, and the screen says so.
@MainActor
@Observable
final class LiveSceneViewModel {
    private(set) var observation: SceneObservation = .empty
    private(set) var hazards: [ElevationHazard] = []
    private(set) var errorMessage: String?
    /// False on a device without LiDAR. People detection still works; the geometry tasks
    /// have nothing to work with.
    private(set) var isDepthAvailable = false
    /// Width / height of the upright camera image, for placing overlay boxes.
    private(set) var imageAspectRatio: CGFloat = 3.0 / 4.0
    /// Camera height above the fitted floor, in metres; nil until a floor is found.
    private(set) var cameraHeight: Float?
    /// Measured analysis rate and latency (T20); nil until a few frames have been timed.
    private(set) var performance: PerformanceMetrics?
    /// ARKit tracking state and camera frame rate, for checking the session on a device (T1).
    private(set) var sessionDescription = ""

    /// nil where ARKit world tracking is unavailable.
    @ObservationIgnored let analyzer: ARSceneAnalyzer?

    // MARK: Field testing (device validation checklist)

    /// Whether frames and announcements are being written to a field-test file.
    private(set) var isRecording = false
    /// Name of the file being written, shown so the tester can say which walk was which.
    private(set) var recordingName: String?
    /// The checklist step most recently marked.
    private(set) var lastMark: String?
    /// Speak delivered announcements and play their haptics here, standing in for the
    /// announcement engine (3.3) until it lands.
    var speaksAnnouncements = true {
        didSet { speaksAnnouncements ? speaker.activate() : speaker.deactivate() }
    }
    /// The most recent delivered announcement, mirrored on screen.
    private(set) var lastAnnouncement: AnnouncementEvent?

    @ObservationIgnored private let announcements: any AnnouncementEngineProtocol
    @ObservationIgnored private let speaker = FieldTestSpeaker()
    @ObservationIgnored private var deliveryTask: Task<Void, Never>?

    /// The device validation checklist in docs/ComputerVision.md, as markers for a recording.
    static let checklistMarks = [
        "1 Session: hold still, then pan",
        "2 Performance: normal walk",
        "3 Floor: chest height",
        "4 Distance: chair at 1 m",
        "4 Distance: chair at 2 m",
        "4 Distance: chair at 3 m",
        "5 Bearing: object on the right",
        "5 Bearing: object on the left",
        "6 Fusion: chair in path",
        "7 Walk toward chair",
        "7 Stand still facing chair",
        "7 Person walking across",
        "7 Person walking toward",
        "8 Kerb / step up",
        "8 Step down / kerb down",
        "8 Stairs down (drop-off)",
        "9 OCR: room sign",
        "10 Long run (thermal)",
    ]

    init(services: AppServices) {
        analyzer = services.scene as? ARSceneAnalyzer
        announcements = services.announcements
    }

    func toggleRecording() {
        guard let recorder = analyzer?.recorder else { return }
        if recorder.isRecording {
            recorder.stop()
            isRecording = false
            return
        }
        do {
            recordingName = try recorder.start().lastPathComponent
            isRecording = true
            lastMark = nil
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func mark(_ label: String) {
        analyzer?.recorder.mark(label)
        lastMark = label
    }

    func start() async {
        guard let analyzer else {
            errorMessage = ARSessionManagerError.worldTrackingUnsupported.localizedDescription
            return
        }
        analyzer.setInterfaceOrientation(.portrait)
        do {
            try await analyzer.start()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        isDepthAvailable = analyzer.sessionManager.isDepthSupported
        if speaksAnnouncements { speaker.activate() }
        deliveryTask?.cancel()
        deliveryTask = Task { [weak self, announcements, recorder = analyzer.recorder] in
            for await event in announcements.deliveredEvents() {
                recorder.recordDelivered(event)
                guard let self else { return }
                self.lastAnnouncement = event
                if self.speaksAnnouncements { self.speaker.deliver(event) }
            }
        }

        for await observation in analyzer.observations() {
            let diagnostics = analyzer.perception.diagnostics
            self.observation = observation
            hazards = observation.elevationHazards
            cameraHeight = diagnostics.cameraHeight
            performance = diagnostics.performance
            sessionDescription = Self.describe(
                tracking: analyzer.sessionManager.trackingStateDescription,
                health: analyzer.sessionManager.healthReport
            )
            imageAspectRatio = CGFloat(diagnostics.uprightAspectRatio)
        }
    }

    func stop() async {
        deliveryTask?.cancel()
        deliveryTask = nil
        speaker.deactivate()
        analyzer?.recorder.stop()
        isRecording = false
        await analyzer?.stop()
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

    private static func describe(tracking: String, health: FrameHealthReport) -> String {
        let fps = health.averageFPS.map { String(format: ", camera %.0f fps", $0) } ?? ""
        let checks = health.passes ? "" : ", move the phone to finish checks"
        return "Tracking \(tracking)\(fps)\(checks)"
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
