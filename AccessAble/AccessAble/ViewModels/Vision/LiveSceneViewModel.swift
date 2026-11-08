import Foundation
import Observation
import UIKit

/// Owner: Computer Vision (1.1). Drives the Live detection screen. For users it reduces the
/// scene to one thing: the nearest object or surface hazard in the path that they asked to
/// hear about (`focus`, `status`), matching what is spoken. In debug builds it also feeds
/// the developer readout of what the pipeline is finding — recognized objects and people
/// (T13, T14), geometric obstacles (T11), the fitted floor (T10), elevation hazards (T12)
/// and measured performance (T20).
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
    /// Moving things predicted to reach the walking path (T34), soonest first.
    private(set) var approaching: [ApproachThreat] = []
    /// Groups of people (T35), nearest first.
    private(set) var crowds: [CrowdRegion] = []
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
    /// The most recent delivered announcement, mirrored on screen.
    private(set) var lastAnnouncement: AnnouncementEvent?
    /// The last announcement while it is fresh; cleared a few seconds after delivery so the
    /// banner doesn't sit over the camera.
    private(set) var visibleAnnouncement: AnnouncementEvent?
    /// The nearest thing in the path the user asked to hear about, once it has held for two
    /// frames. What the screen outlines, so one box moves smoothly instead of many flickering.
    private(set) var focus: Detection?
    /// False until the first analyzed frame arrives.
    private(set) var hasObservation = false
    /// `Detection.id`s inside the walking corridor in the current observation.
    private(set) var inPath: Set<UUID> = []

    @ObservationIgnored private let announcements: any AnnouncementEngineProtocol
    /// Holds the screen awake and speaks up when guidance stops or returns (T27).
    @ObservationIgnored private let guidance: GuidanceStatusMonitor
    @ObservationIgnored private var deliveryTask: Task<Void, Never>?
    @ObservationIgnored private var elevationScenarioTask: Task<Void, Never>?
    @ObservationIgnored private var orientationTask: Task<Void, Never>?
    @ObservationIgnored private let pointIdentifier = PointIdentifier()
    @ObservationIgnored private let alertSettings: AlertSettings
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    /// Track of the current `focus`, and a new one waiting to be confirmed.
    @ObservationIgnored private var focusTrack: UUID?
    @ObservationIgnored private var focusCandidate: UUID?
    @ObservationIgnored private var focusCandidateFrames = 0
    @ObservationIgnored private var focusLastSeen: TimeInterval = 0

    /// Inside this, in metres, the announcer says "Stop" and nothing is filtered out.
    static let stopDistance = Double(ObstacleAnnouncer().thresholds.last ?? 1.2)
    /// How long the focus outline outlives its last sighting, so one missed frame doesn't blink it.
    private static let focusGrace: TimeInterval = 0.6
    /// How long the banner stays up after an announcement.
    private static let bannerDuration: Duration = .seconds(4)

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
        alertSettings = services.alertSettings
        guidance = GuidanceStatusMonitor(announcements: services.announcements)
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

    /// Speaks what is in the middle of the frame (T43). A reply to a tap, so it is sent as
    /// `.userInteraction`: the engine neither filters it by category nor drops a second tap
    /// on the same thing as a duplicate.
    func identifyPointedAt() {
        let text = pointIdentifier.spokenIdentification(in: observation) ?? "Nothing recognized."
        let event = AnnouncementEvent(
            category: .system,
            priority: .normal,
            text: text,
            source: .userInteraction,
            expiresAt: Date().addingTimeInterval(3)
        )
        Task { [announcements] in
            await announcements.submit(event)
        }
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

    /// Holds the shared camera until the calling task is cancelled.
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
        guidance.watch(analyzer)
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
                self.show(event)
            }
        }

        for await observation in analyzer.observations() {
            let diagnostics = analyzer.perception.diagnostics
            self.observation = observation
            hasObservation = true
            inPath = diagnostics.inPath
            updateFocus()
            hazards = observation.elevationHazards
            cameraHeight = diagnostics.cameraHeight
            isFloorMeasured = diagnostics.isFloorMeasured
            path = diagnostics.path
            approaching = diagnostics.approaching
            crowds = diagnostics.crowds
            navigation = diagnostics.navigation
            performance = diagnostics.performance
            sessionDescription = Self.describe(
                tracking: analyzer.sessionManager.trackingStateDescription,
                health: analyzer.sessionManager.healthReport
            )
            imageAspectRatio = CGFloat(diagnostics.uprightAspectRatio)
        }
        await analyzer.stop()
    }

    func stop() {
        guidance.stop()
        deliveryTask?.cancel()
        deliveryTask = nil
        bannerTask?.cancel()
        bannerTask = nil
        elevationScenarioTask?.cancel()
        elevationScenarioTask = nil
        orientationTask?.cancel()
        orientationTask = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        analyzer?.recorder.stop()
        // Other features share the analyzer and don't follow the device's orientation.
        analyzer?.setInterfaceOrientation(.portrait)
        isRecording = false
    }

    // MARK: What the user sees

    /// What the status strip says: the same thing the voice is warning about, in a word or two.
    struct PathStatus: Equatable {
        enum Level { case starting, clear, caution, stop }
        let level: Level
        let title: String
        /// The way round, e.g. "Go left".
        let detail: String?
    }

    var status: PathStatus {
        guard hasObservation else { return PathStatus(level: .starting, title: "Starting camera…", detail: nil) }
        let filter = alertSettings.filter
        var nearest: (name: String, distance: Double, bearing: RelativeBearing?)?
        if let focus, let distance = focus.cautiousDistance {
            nearest = (Self.displayName(of: focus), distance, focus.bearing)
        }
        for hazard in hazards where hazard.type != .unknown
            && (hazard.type == .dropOff || filter.allows(DangerLevel(of: hazard.type))) {
            // As in the announcer, a drop-off keeps at least the default warning distance.
            let reach = hazard.type == .dropOff ? max(filter.maximumDistance, AlertFilter.default.maximumDistance) : filter.maximumDistance
            let distance = Double(hazard.distance)
            guard hazard.distance <= reach, distance < nearest?.distance ?? .infinity else { continue }
            nearest = (SpokenPhrasing.name(of: hazard.type), distance, .ahead)
        }
        guard let nearest else {
            // Without depth, nothing seen doesn't mean nothing there.
            return PathStatus(level: .clear, title: isDepthAvailable ? "Path clear" : "Watching ahead", detail: nil)
        }
        let isStop = nearest.distance <= Self.stopDistance
        let advice = SpokenPhrasing.advice(for: path, bearing: nearest.bearing, critical: isStop)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        if isStop {
            return PathStatus(level: .stop, title: "Stop · \(nearest.name)", detail: advice)
        }
        return PathStatus(level: .caution, title: String(format: "%@ · %.1f m", nearest.name, nearest.distance), detail: advice)
    }

    /// What the outline's tag says: "Chair · 1.2 m".
    var focusCaption: String? {
        guard let focus else { return nil }
        guard let distance = focus.distance else { return Self.displayName(of: focus) }
        return String(format: "%@ · %.1f m", Self.displayName(of: focus), distance)
    }

    private static func displayName(of detection: Detection) -> String {
        detection.label.prefix(1).uppercased() + detection.label.dropFirst()
    }

    /// Picks the nearest in-path detection the user's filter lets through, and only moves the
    /// outline to a different object once that object has been nearest for two frames.
    private func updateFocus() {
        let filter = alertSettings.filter
        let candidates = observation.detections.filter { detection in
            guard inPath.contains(detection.id), let distance = detection.cautiousDistance,
                  distance <= Double(filter.maximumDistance)
            else { return false }
            return filter.allows(DangerLevel(of: detection)) || distance <= Self.stopDistance
        }
        let now = ProcessInfo.processInfo.systemUptime
        let nearest = candidates.min { $0.cautiousDistance! < $1.cautiousDistance! }
        let key = nearest.map { $0.trackID ?? $0.id }

        if let nearest, let key {
            if key == focusTrack {
                focus = nearest
                focusLastSeen = now
            } else if key == focusCandidate {
                focusCandidateFrames += 1
                if focusCandidateFrames >= 2 {
                    focus = nearest
                    focusTrack = key
                    focusLastSeen = now
                    focusCandidate = nil
                }
            } else {
                focusCandidate = key
                focusCandidateFrames = 1
            }
        }
        // Still visible but no longer nearest: follow it until its grace runs out.
        if let focusTrack, key != focusTrack,
           let current = candidates.first(where: { ($0.trackID ?? $0.id) == focusTrack }) {
            focus = current
        }
        if focus != nil, now - focusLastSeen > Self.focusGrace {
            focus = nil
            focusTrack = nil
        }
    }

    private func show(_ event: AnnouncementEvent) {
        lastAnnouncement = event
        visibleAnnouncement = event
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: Self.bannerDuration)
            guard !Task.isCancelled, let self, self.visibleAnnouncement?.id == event.id else { return }
            self.visibleAnnouncement = nil
        }
    }

    // MARK: Developer readout

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

    /// "Car from your right, 1.4 s, 6.2 m/s" — one approach, for checking T34 against what
    /// is actually happening in front of the tester.
    func approachLine(_ threat: ApproachThreat) -> String {
        let name = threat.label.prefix(1).uppercased() + threat.label.dropFirst()
        let side = SpokenPhrasing.approachSide(threat.bearing)
        return String(format: "%@ %@, %.1f s, %.1f m/s", name, side, threat.timeToApproach, threat.speed)
    }

    /// "6 people, 3.5 m, 2.4 m wide" — one group, for checking T35 against the pavement in
    /// front of the tester.
    func crowdLine(_ crowd: CrowdRegion) -> String {
        String(format: "%d people, %.1f m, %.1f m wide", crowd.count, crowd.nearestDistance, crowd.extent)
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
