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
    /// "Ground ahead: floor 92%" from segmentation, plus how many drops it dismissed.
    private(set) var surfaceDescription: String?
    /// Milliseconds per stage of `analyze`, smoothed over the last second or so, in order.
    private(set) var stageTimes: [(name: String, milliseconds: Double)] = []
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
    /// Walk, Find, Read or Describe. Each runs only the parts of the pipeline it needs.
    var mode: LiveMode = .walk {
        didSet {
            guard mode != oldValue else { return }
            analyzer?.setMode(mode)
            if oldValue == .find, isNavigating { stopNavigating() }
        }
    }
    /// True while "Describe" is waiting for its answer.
    private(set) var isDescribing = false
    /// Ask AI (T19), in Describe mode: the latest answer, or why there isn't one.
    private(set) var answer: String?
    private(set) var askError: String?
    private(set) var isAsking = false
    /// The camera image the latest answer was based on, for a sighted helper to check.
    private(set) var askedImage: UIImage?
    /// The questions and answers so far, so follow-ups make sense. Kept until "New
    /// conversation" or leaving the screen.
    private(set) var conversation = AskAIConversation()
    /// What dictation has heard so far, shown while listening.
    private(set) var heard = ""
    /// True while the answer was "not in view" and the camera keeps looking as the user turns.
    private(set) var isLookingAgain = false
    /// True while the microphone is listening for a question.
    var isListening: Bool { dictation.isRecording }
    /// What the voice is warning about right now, nil when the path is clear.
    private(set) var warning: PathWarning?
    /// The object that warning is about, when it is one we can see. What the screen outlines,
    /// so one box moves smoothly instead of many flickering.
    private(set) var focus: Detection?
    /// False until the first analyzed frame arrives.
    private(set) var hasObservation = false
    /// "Take me to…" progress for the screen. A finished request ("Arrived", "Could not
    /// find") is shown for a few seconds, then cleared.
    private(set) var navigationMessage: String?

    @ObservationIgnored private let announcements: any AnnouncementEngineProtocol
    /// Holds the screen awake and speaks up when guidance stops or returns (T27).
    @ObservationIgnored private let guidance: GuidanceStatusMonitor
    @ObservationIgnored private var deliveryTask: Task<Void, Never>?
    @ObservationIgnored private var elevationScenarioTask: Task<Void, Never>?
    @ObservationIgnored private var orientationTask: Task<Void, Never>?
    @ObservationIgnored private let pointIdentifier = PointIdentifier()
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private let dictation = SpeechDictation()
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var askTask: Task<Void, Never>?

    /// Dictation stops after this long without new words, so a question needs no second tap.
    private static let silenceTimeout: Duration = .milliseconds(2_500)
    /// After "not in view", how long to keep looking while the user turns, and how often.
    private static let keepLookingFor: Duration = .seconds(20)
    private static let lookAgainEvery: Duration = .seconds(2)
    @ObservationIgnored private var focusLastSeen: TimeInterval = 0
    /// When the current "take me to…" request finished, if it has.
    @ObservationIgnored private var navigationEndedAt: TimeInterval?

    /// How long the focus outline outlives its last sighting, so one missed frame doesn't blink it.
    private static let focusGrace: TimeInterval = 0.6
    /// How long "Arrived" or "Could not find" stays on screen.
    private static let finishedNavigationDuration: TimeInterval = 4
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

    init(services: AppServices, mode: LiveMode = .walk) {
        self.mode = mode
        analyzer = services.scene as? ARSceneAnalyzer
        announcements = services.announcements
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

    /// Says the last sign again.
    func readAgain() {
        guard let text = lastReading else { return }
        let event = AnnouncementEvent(category: .landmark, priority: .high, text: text, source: .userInteraction)
        Task { [announcements] in await announcements.submit(event) }
    }

    /// Speaks a description of what the camera sees: the same answer as "Describe my
    /// surroundings" on Home, from the live session the screen is already running.
    func describe() {
        guard let analyzer, !isDescribing else { return }
        isDescribing = true
        Task { [weak self, announcements] in
            let text = await analyzer.describeCurrentScene()
            await announcements.submit(
                AnnouncementEvent(category: .ambient, priority: .high, text: text, source: .userInteraction)
            )
            self?.isDescribing = false
        }
    }

    // MARK: Ask AI conversation

    /// Starts listening for a spoken question; tapping again while listening sends what was
    /// heard. Listening also stops on its own after a pause.
    func toggleListening() async {
        if isListening {
            dictation.stop()
            return
        }
        guard !isAsking else { return }
        heard = ""
        dictation.onTranscript = { [weak self] text, isFinal in self?.didHear(text, isFinal: isFinal) }
        dictation.onError = { [weak self] message in self?.speak(message) }
        await dictation.start()
        if isListening { armSilenceTimer() }
    }

    private func didHear(_ text: String, isFinal: Bool) {
        heard = text
        guard isFinal else {
            armSilenceTimer()
            return
        }
        silenceTask?.cancel()
        ask(text)
    }

    private func armSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.silenceTimeout)
            guard !Task.isCancelled else { return }
            self?.dictation.stop()
        }
    }

    /// Asks about the camera view with the conversation so far, and speaks the answer. When
    /// the answer is that it isn't in view, says to turn slowly and keeps looking with fresh
    /// frames for a while, speaking once it finds an answer.
    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let analyzer, !question.isEmpty else { return }
        askTask?.cancel()
        isAsking = true
        answer = nil
        askError = nil
        askTask = Task { [weak self] in
            await self?.converse(question, with: analyzer)
        }
    }

    private func converse(_ question: String, with analyzer: ARSceneAnalyzer) async {
        defer {
            isAsking = false
            isLookingAgain = false
        }
        let history = conversation.turns
        var reply: String
        do {
            reply = try await analyzer.ask(question, conversation: history)
        } catch {
            guard !Task.isCancelled else { return }
            askError = error.localizedDescription
            askedImage = analyzer.lastAskedImage.flatMap { UIImage(data: $0) }
            speak(error.localizedDescription)
            return
        }

        if AskAIConversation.meansNotInView(reply) {
            speak("I can't see that yet. Turn slowly and I'll tell you when I find it.")
            isLookingAgain = true
            let deadline = ContinuousClock.now + Self.keepLookingFor
            var found: String?
            while found == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: Self.lookAgainEvery)
                guard !Task.isCancelled else { return }
                if let again = try? await analyzer.ask(question, conversation: history),
                   !AskAIConversation.meansNotInView(again) {
                    found = again
                }
            }
            reply = found ?? "I couldn't find it. Try moving closer, or ask again."
        }
        guard !Task.isCancelled else { return }
        answer = reply
        askedImage = analyzer.lastAskedImage.flatMap { UIImage(data: $0) }
        conversation.record(question: question, answer: reply)
        speak(reply)
    }

    /// Forgets the conversation and stops anything in progress.
    func newConversation() {
        askTask?.cancel()
        silenceTask?.cancel()
        dictation.cancel()
        conversation.reset()
        answer = nil
        askError = nil
        askedImage = nil
        heard = ""
        isAsking = false
        isLookingAgain = false
        speak("New conversation.")
    }

    private func speak(_ text: String) {
        let event = AnnouncementEvent(category: .ambient, priority: .high, text: text, source: .userInteraction)
        Task { [announcements] in await announcements.submit(event) }
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
        analyzer.setMode(mode)
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
            warning = diagnostics.warning
            updateFocus()
            hazards = observation.elevationHazards
            cameraHeight = diagnostics.cameraHeight
            isFloorMeasured = diagnostics.isFloorMeasured
            path = diagnostics.path
            approaching = diagnostics.approaching
            crowds = diagnostics.crowds
            navigation = diagnostics.navigation
            updateNavigationMessage()
            performance = diagnostics.performance
            smoothStageTimes(diagnostics.stages)
            surfaceDescription = diagnostics.surfaceAhead.map { surface in
                String(format: "Ground ahead: %@ %.0f%%", surface.kind.rawValue, surface.share * 100)
                    + (diagnostics.hazardsDismissedBySurface > 0 ? ", \(diagnostics.hazardsDismissedBySurface) drop(s) dismissed" : "")
            }
            sessionDescription = Self.describe(
                tracking: analyzer.sessionManager.trackingStateDescription,
                health: analyzer.sessionManager.healthReport
            )
            imageAspectRatio = CGFloat(diagnostics.uprightAspectRatio)
        }
        await analyzer.stop()
    }

    func stop() {
        askTask?.cancel()
        silenceTask?.cancel()
        dictation.cancel()
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
        // Other features share the analyzer and don't follow the device's orientation, and
        // trips expect the full obstacle warnings of Walk.
        analyzer?.setInterfaceOrientation(.portrait)
        analyzer?.setMode(.walk)
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
        // Read and Describe only ever warn with "Stop"; otherwise the strip says what to do.
        if mode == .read || mode == .describe, warning?.isStop != true {
            return modeHint
        }
        guard let warning else {
            // Without depth, nothing seen doesn't mean nothing there.
            return PathStatus(level: .clear, title: isDepthAvailable ? "Path clear" : "Watching ahead", detail: nil)
        }
        if warning.isStop {
            return PathStatus(level: .stop, title: "Stop · \(warning.name)", detail: warning.advice)
        }
        let title = warning.distance.map { String(format: "%@ · %.1f m", warning.name, $0) } ?? warning.name
        return PathStatus(level: .caution, title: title, detail: warning.advice)
    }

    private var modeHint: PathStatus {
        switch mode {
        case .read:
            PathStatus(level: .starting, title: lastReading ?? "Point at a sign", detail: lastReading == nil ? "Text is read aloud" : nil)
        case .describe:
            PathStatus(level: .starting, title: isDescribing ? "Looking…" : "Tap Describe or Identify", detail: nil)
        case .walk, .find:
            PathStatus(level: .starting, title: "", detail: nil)
        }
    }

    /// The last sign or text read aloud in Read mode.
    var lastReading: String? {
        guard let event = lastAnnouncement, event.source == .textRecognition else { return nil }
        return event.text
    }

    /// What the outline's tag says: "Chair · 1.2 m".
    var focusCaption: String? {
        guard focus != nil, let warning else { return nil }
        return warning.distance.map { String(format: "%@ · %.1f m", warning.name, $0) } ?? warning.name
    }

    /// Outlines the object the warning is about, following its track from frame to frame.
    private func updateFocus() {
        let now = ProcessInfo.processInfo.systemUptime
        if let track = warning?.trackID, let match = observation.detections.first(where: { $0.trackID == track }) {
            focus = match
            focusLastSeen = now
        } else if focus != nil, now - focusLastSeen > Self.focusGrace {
            focus = nil
        }
    }

    private func updateNavigationMessage() {
        guard let navigation else {
            navigationMessage = nil
            navigationEndedAt = nil
            return
        }
        switch navigation.phase {
        case .scanning, .guiding:
            navigationEndedAt = nil
            navigationMessage = navigation.description
        case .arrived, .notFound:
            let now = ProcessInfo.processInfo.systemUptime
            let ended = navigationEndedAt ?? now
            navigationEndedAt = ended
            navigationMessage = now - ended < Self.finishedNavigationDuration ? navigation.description : nil
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

    /// "Objects 80 · Mesh 2 · Depth 70 · Warnings 3 ms" — where each frame's time goes.
    var stagesDescription: String? {
        guard !stageTimes.isEmpty else { return nil }
        return stageTimes.map { String(format: "%@ %.0f", $0.name, $0.milliseconds) }.joined(separator: " · ") + " ms"
    }

    /// Averages each stage over roughly the last ten frames, so the readout can be read.
    private func smoothStageTimes(_ stages: [ScenePerception.StageTiming]) {
        let previous = Dictionary(stageTimes.map { ($0.name, $0.milliseconds) }, uniquingKeysWith: { a, _ in a })
        stageTimes = stages.map { stage in
            let smoothed = previous[stage.name].map { $0 * 0.9 + stage.milliseconds * 0.1 } ?? stage.milliseconds
            return (stage.name, smoothed)
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
