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
    /// False while the floor is remembered or assumed rather than seen this frame.
    private(set) var isFloorMeasured = false
    /// Which way the geometry says is open; nil without depth.
    private(set) var path: PathAssessment?
    /// Progress of "Take me to…", nil when no request is active or finished.
    private(set) var navigation: NavigationStatus?
    /// How the phone is held. Landscape widens the horizontal field of view from about
    /// 50° to about 70°, so more of the room is seen at once; the pipeline follows it.
    private(set) var interfaceOrientation: UIInterfaceOrientation = .portrait
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
    /// Ground truth entered by the tester before recording an elevation scenario. These stay
    /// as strings for SwiftUI editing and are parsed only when written to the JSONL record.
    var elevationPhysicalSetup = ""
    var elevationSurfaceType = ""
    var elevationExpectedHeight = ""
    var elevationExpectedDistance = ""
    var elevationExpectedHazard = "step / curb"
    private(set) var elevationValidationMessage: String?
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
    @ObservationIgnored private var elevationScenarioTask: Task<Void, Never>?
    @ObservationIgnored private var orientationTask: Task<Void, Never>?

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
            elevationValidationMessage = nil
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func mark(_ label: String) {
        analyzer?.recorder.mark(label)
        lastMark = label
    }

    /// Mirrored from the recorder's status stream; lifecycle ownership remains in the recorder.
    private(set) var hasActiveElevationSetup = false

    func recordElevationSetup() {
        guard let recorder = analyzer?.recorder, recorder.isRecording else { return }
        guard let setup = validatedElevationSetup() else { return }
        switch recorder.recordElevationSetup(setup, environment: testEnvironment) {
        case .recorded:
            elevationValidationMessage = nil
            lastMark = "Elevation setup recorded"
        case .activeSetupExists:
            elevationValidationMessage = "Record an outcome before starting another elevation setup."
        case .notRecording:
            elevationValidationMessage = "Start field-test recording before recording an elevation setup."
        }
    }

    func recordElevationOutcome(_ outcome: String) {
        guard let recorder = analyzer?.recorder, recorder.isRecording else { return }
        switch recorder.recordElevationOutcome(outcome, environment: testEnvironment) {
        case .recorded:
            elevationValidationMessage = nil
            lastMark = "Outcome: \(outcome)"
        case .noActiveSetup:
            elevationValidationMessage = "Record a complete elevation setup before its outcome."
        case .noFramesRecorded:
            elevationValidationMessage = "Wait for at least one analyzed frame before recording the outcome."
        }
    }

    /// Starts steering towards `query`; an empty query cancels.
    func navigate(to query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        analyzer?.navigate(to: trimmed.isEmpty ? nil : trimmed)
        if trimmed.isEmpty { navigation = nil }
    }

    func stopNavigating() {
        analyzer?.navigate(to: nil)
        navigation = nil
    }

    var isNavigating: Bool {
        switch navigation?.phase {
        case .scanning, .guiding: true
        default: false
        }
    }

    func start() async {
        guard let analyzer else {
            errorMessage = ARSessionManagerError.worldTrackingUnsupported.localizedDescription
            return
        }
        followDeviceOrientation(analyzer)
        do {
            try await analyzer.start()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        isDepthAvailable = analyzer.sessionManager.isDepthSupported
        if speaksAnnouncements { speaker.activate() }
        elevationScenarioTask?.cancel()
        elevationScenarioTask = Task { [weak self, recorder = analyzer.recorder] in
            for await isActive in recorder.elevationScenarioStatuses() {
                guard let self, !Task.isCancelled else { return }
                self.hasActiveElevationSetup = isActive
            }
        }
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
            isFloorMeasured = diagnostics.isFloorMeasured
            path = diagnostics.path
            navigation = diagnostics.navigation
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
        elevationScenarioTask?.cancel()
        elevationScenarioTask = nil
        orientationTask?.cancel()
        orientationTask = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
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
        let source = isFloorMeasured ? "Floor found" : "Floor remembered"
        return String(format: "%@, camera %.2f m above it", source, height)
    }

    /// "Path clear" / "Go left" / "Blocked", for the readout.
    var pathDescription: String? {
        guard let path else { return nil }
        return switch path.clearDirection {
        case .ahead: path.isNarrow ? "Narrow gap ahead" : "Path clear"
        case .left: "Blocked — go left"
        case .right: "Blocked — go right"
        case .blocked:
            switch path.turn {
            case .left: "Blocked — turn left"
            case .right: "Blocked — turn right"
            case nil: "Blocked — no clear path"
            }
        }
    }

    var performanceDescription: String? {
        performance.map {
            String(format: "%.0f fps, %.0f ms (p95 %.0f ms)", $0.averageFPS, $0.averageLatencyMilliseconds, $0.p95LatencyMilliseconds)
        }
    }

    /// Keeps the analyzer's idea of "upright" in step with how the phone is held, so
    /// Vision sees upright images and boxes land on the rotated preview.
    private func followDeviceOrientation(_ analyzer: ARSceneAnalyzer) {
        func apply(_ device: UIDeviceOrientation) {
            // Device and interface landscape are mirror images of each other.
            let interface: UIInterfaceOrientation? = switch device {
            case .portrait: .portrait
            case .landscapeLeft: .landscapeRight
            case .landscapeRight: .landscapeLeft
            default: nil // Face up/down and upside down: keep what we had.
            }
            guard let interface else { return }
            interfaceOrientation = interface
            analyzer.setInterfaceOrientation(interface)
        }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        apply(UIDevice.current.orientation)
        analyzer.setInterfaceOrientation(interfaceOrientation)
        orientationTask?.cancel()
        orientationTask = Task { @MainActor in
            for await _ in NotificationCenter.default.notifications(named: UIDevice.orientationDidChangeNotification) {
                apply(UIDevice.current.orientation)
            }
        }
    }

    private static func describe(tracking: String, health: FrameHealthReport) -> String {
        let fps = health.averageFPS.map { String(format: ", camera %.0f fps", $0) } ?? ""
        let checks = health.passes ? "" : ", move the phone to finish checks"
        return "Tracking \(tracking)\(fps)\(checks)"
    }

    private func validatedElevationSetup() -> FieldTestRecorder.ElevationSetup? {
        let physicalSetup = elevationPhysicalSetup.trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceType = elevationSurfaceType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !physicalSetup.isEmpty, !surfaceType.isEmpty,
              let expectedHeight = Float(elevationExpectedHeight), expectedHeight.isFinite, expectedHeight >= 0,
              let expectedDistance = Float(elevationExpectedDistance), expectedDistance.isFinite, expectedDistance >= 0
        else {
            elevationValidationMessage = "Enter setup, surface, and nonnegative expected height and distance in metres."
            return nil
        }
        return FieldTestRecorder.ElevationSetup(
            scenarioID: UUID(),
            physicalSetup: physicalSetup,
            surfaceType: surfaceType,
            expectedHeight: expectedHeight,
            expectedDistance: expectedDistance,
            expectedHazard: elevationExpectedHazard
        )
    }

    private var testEnvironment: FieldTestRecorder.TestEnvironment {
        FieldTestRecorder.TestEnvironment(
            tracking: analyzer?.sessionManager.trackingStateDescription ?? "unavailable",
            thermal: ProcessInfo.processInfo.thermalState.name
        )
    }

    var countsDescription: String {
        let counts = "\(people.count) person(s), \(obstacles.count) obstacle(s) in your path"
        return pathDescription.map { "\(counts). \($0)" } ?? counts
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
