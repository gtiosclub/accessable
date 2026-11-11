import Foundation
import Synchronization
import os

/// Owner: Computer Vision (1.4). Records what the pipeline saw and said, frame by frame,
/// during an on-device test walk, so the device validation checklist can be checked
/// against data rather than by watching the screen.
///
/// Each recording is one JSON Lines file in `Documents/FieldTests/`, one object per line:
/// `{"kind":"frame",…}` for every analyzed frame, `{"kind":"delivered",…}` for every
/// announcement the engine delivered, `{"kind":"mark",…}` when the tester marks a checklist
/// step, and `elevationSetup` / `elevationOutcome` records for calibration passes. Elevation
/// records and their frames share `elevationScenarioID`. Copy them off the phone with
/// `xcrun devicectl device copy from --domain-type appDataContainer …`.
///
/// Recording is off by default and `record` returns immediately while it is off, so the
/// recorder can sit in the live pipeline permanently. Writes happen on a utility queue,
/// never on the analysis queue.
final class FieldTestRecorder: Sendable {
    /// Tester-entered ground truth for one elevation scenario. The frame records that follow
    /// carry the detector's measured distance and height; keeping this separate makes it
    /// possible to compare them without treating a preset scenario name as ground truth.
    struct ElevationSetup: Codable, Sendable {
        /// Stable ID linking setup, outcome, and all frame records in this test pass.
        let scenarioID: UUID
        let physicalSetup: String
        let surfaceType: String
        let expectedHeight: Float?
        let expectedDistance: Float?
        let expectedHazard: String
    }

    /// Conditions at a tester action. Frame records contain the same information over time;
    /// recording it here makes a setup or outcome independently interpretable in JSONL.
    struct TestEnvironment: Codable, Sendable {
        let tracking: String
        let thermal: String
    }

    enum ElevationOutcomeResult: Sendable, Equatable {
        case recorded
        case noActiveSetup
        case noFramesRecorded
    }

    enum ElevationSetupResult: Sendable, Equatable {
        case recorded
        case activeSetupExists
        case notRecording
    }
    struct DetectionRecord: Codable, Sendable {
        let label: String
        let origin: String
        let confidence: Float
        let distance: Double?
        let bearingDegrees: Double?
        /// First 8 characters of the track ID, enough to follow one object through a file.
        let track: String?
        let inPath: Bool
    }

    struct HazardRecord: Codable, Sendable {
        let type: String
        let distance: Float
        let heightChange: Float
    }

    struct EventRecord: Codable, Sendable {
        /// Preserves the originating event through asynchronous delivery.
        let id: UUID
        let text: String
        let priority: Int
        let haptic: String?
        let dedupKey: String?
        /// Retained so scenario attribution can expire when the engine would drop this event.
        let createdAt: Date
        let expiresAt: Date?
    }

    struct FrameRecord: Codable, Sendable {
        var kind = "frame"
        /// `ARFrame.timestamp`: seconds of system uptime when the camera captured the frame.
        let t: TimeInterval
        /// From capture to the end of analysis: the delay the user actually experiences.
        let captureToResultMs: Double
        let processingMs: Double
        let ocrBusy: Bool
        let tracking: String
        let cameraFPS: Double?
        let thermal: String
        let lowPower: Bool
        let hasDepth: Bool
        let cameraHeight: Float?
        /// False when the floor was remembered or assumed rather than fitted this frame.
        let floorMeasured: Bool
        /// The active elevation setup, when a tester has recorded one for this pass.
        var elevationScenarioID: UUID?
        /// `ClearDirection` the geometry chose, e.g. "left"; nil without depth.
        let path: String?
        let detections: [DetectionRecord]
        let hazards: [HazardRecord]
        let emitted: [EventRecord]
        let text: [String]
    }

    private struct DeliveredRecord: Codable {
        var kind = "delivered"
        let t: TimeInterval
        /// The originating elevation scenario, retained for late delivery after closure.
        let elevationScenarioID: UUID?
        let event: EventRecord
    }

    private struct MarkRecord: Codable {
        var kind = "mark"
        let t: TimeInterval
        let label: String
    }

    private struct ElevationSetupRecord: Codable {
        var kind = "elevationSetup"
        let t: TimeInterval
        let setup: ElevationSetup
        let environment: TestEnvironment
    }

    private struct ElevationOutcomeRecord: Codable {
        var kind = "elevationOutcome"
        let t: TimeInterval
        /// What the tester reported hearing/seeing. It is not itself proof of engine delivery.
        let outcome: String
        /// Number of scenario-linked events the engine delivered before this outcome was marked.
        let deliveredEventCount: Int
        let setup: ElevationSetup
        let environment: TestEnvironment
    }

    private struct State {
        var handle: FileHandle?
        var url: URL?
        /// The immutable setup is the source of truth for the outcome record. Keeping it here
        /// prevents later edits in the UI from changing a pass's ground truth.
        var activeElevationSetup: ElevationSetup?
        var activeElevationHasFrame = false
        var activeElevationDeliveredEventIDs = Set<UUID>()
        /// Delivery can happen after the tester closes a scenario. Retain its origin only
        /// through the event's stale window, then discard it to bound recording memory.
        var emittedEventScenarios: [UUID: EventScenario] = [:]
    }

    private struct EventScenario {
        let scenarioID: UUID
        let expiresAt: Date
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "AccessAble.FieldTestRecorder", qos: .utility)
    private let cleanupQueue = DispatchQueue(label: "AccessAble.FieldTestRecorder.cleanup", qos: .utility)
    private let log = Logger(subsystem: "AccessAble", category: "FieldTestRecorder")

    private static let eventDeliveryGrace: TimeInterval = 1

    var isRecording: Bool { state.withLock { $0.handle != nil } }
    var hasActiveElevationSetup: Bool { state.withLock { $0.activeElevationSetup != nil } }
    /// Replays the recorder-owned scenario state so controls refresh after external changes.
    private let elevationScenarioStatus = Broadcaster<Bool>(replaysLatest: true)

    func elevationScenarioStatuses() -> AsyncStream<Bool> {
        elevationScenarioStatus.stream()
    }

    static var directory: URL {
        URL.documentsDirectory.appending(path: "FieldTests", directoryHint: .isDirectory)
    }

    /// Starts a new recording, ending any current one. Returns the file it writes to.
    @discardableResult
    func start() throws -> URL {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let name = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let url = Self.directory.appending(path: "walk-\(name).jsonl")
        FileManager.default.createFile(atPath: url.path(), contents: nil)
        let handle = try FileHandle(forWritingTo: url)

        let previous = state.withLock { state in
            defer { state = State(handle: handle, url: url) }
            elevationScenarioStatus.send(false)
            return state.handle
        }
        queue.async { try? previous?.close() }
        log.notice("recording to \(url.lastPathComponent, privacy: .public)")
        return url
    }

    func stop() {
        let handle = state.withLock { state in
            defer { state = State() }
            elevationScenarioStatus.send(false)
            return state.handle
        }
        queue.async { try? handle?.close() }
    }

    /// Marks the moment a checklist step starts, e.g. "chair 2 m ahead".
    func mark(_ label: String) {
        write(MarkRecord(t: ProcessInfo.processInfo.systemUptime, label: label))
    }

    /// Records tape-measured ground truth before approaching an elevation feature.
    @discardableResult
    func recordElevationSetup(_ setup: ElevationSetup, environment: TestEnvironment) -> ElevationSetupResult {
        let result: ElevationSetupResult = state.withLock {
            guard let handle = $0.handle else { return .notRecording }
            guard $0.activeElevationSetup == nil else { return .activeSetupExists }
            $0.activeElevationSetup = setup
            $0.activeElevationHasFrame = false
            $0.activeElevationDeliveredEventIDs = []
            enqueue(ElevationSetupRecord(t: ProcessInfo.processInfo.systemUptime, setup: setup, environment: environment), to: handle)
            elevationScenarioStatus.send(true)
            return .recorded
        }
        return result
    }

    /// Records the tester's outcome after the pass. Delivered events in the same file show
    /// what the announcement engine actually emitted.
    /// Finishes the current scenario. An outcome without an associated analyzed frame is not
    /// calibration evidence and is deliberately rejected rather than written as a valid pass.
    func recordElevationOutcome(_ outcome: String, environment: TestEnvironment) -> ElevationOutcomeResult {
        let result = state.withLock { state -> ElevationOutcomeResult in
            guard let handle = state.handle, let setup = state.activeElevationSetup else { return .noActiveSetup }
            guard state.activeElevationHasFrame else { return .noFramesRecorded }
            enqueue(ElevationOutcomeRecord(
                t: ProcessInfo.processInfo.systemUptime,
                outcome: outcome,
                deliveredEventCount: state.activeElevationDeliveredEventIDs.count,
                setup: setup,
                environment: environment
            ), to: handle)
            state.activeElevationSetup = nil
            state.activeElevationHasFrame = false
            state.activeElevationDeliveredEventIDs = []
            elevationScenarioStatus.send(false)
            return .recorded
        }
        return result
    }

    func record(_ frame: @autoclosure () -> FrameRecord) {
        // Keep the old fast path: constructing a frame record walks every detection and must
        // not happen when field recording is disabled.
        guard state.withLock({ $0.handle != nil }) else { return }
        var record = frame()
        let didEnqueue = state.withLock { state -> Bool in
            guard let handle = state.handle else { return false }
            pruneExpiredEventScenarios(in: &state, now: .now)
            let scenarioID = state.activeElevationSetup?.scenarioID
            record.elevationScenarioID = scenarioID
            if let scenarioID {
                state.activeElevationHasFrame = true
                for event in record.emitted {
                    guard let expiresAt = event.expiresAt else { continue }
                    let mappingExpiresAt = expiresAt.addingTimeInterval(Self.eventDeliveryGrace)
                    state.emittedEventScenarios[event.id] = EventScenario(
                        scenarioID: scenarioID,
                        expiresAt: mappingExpiresAt
                    )
                    scheduleEventScenarioCleanup(at: mappingExpiresAt)
                }
            }
            // This occurs while the state lock is held, so an outcome cannot enter the
            // writer queue before the frame that made it eligible.
            enqueue(record, to: handle)
            return true
        }
        guard didEnqueue else { return }
    }

    func recordDelivered(_ event: AnnouncementEvent) {
        state.withLock { state in
            guard let handle = state.handle else { return }
            // Do not attribute unrelated announcement-engine events merely because a field
            // scenario happens to be active. Only this pipeline's recorded emission maps one.
            pruneExpiredEventScenarios(in: &state, now: .now)
            let scenarioID = state.emittedEventScenarios.removeValue(forKey: event.id)?.scenarioID
            if let activeID = state.activeElevationSetup?.scenarioID, activeID == scenarioID {
                state.activeElevationDeliveredEventIDs.insert(event.id)
            }
            enqueue(DeliveredRecord(
                t: ProcessInfo.processInfo.systemUptime,
                elevationScenarioID: scenarioID,
                event: EventRecord(event)
            ), to: handle)
        }
    }

    private func write(_ record: some Encodable & Sendable) {
        guard let handle = state.withLock({ $0.handle }) else { return }
        enqueue(record, to: handle)
    }

    private func enqueue(_ record: some Encodable & Sendable, to handle: FileHandle) {
        queue.async { [log] in
            do {
                var line = try JSONEncoder().encode(record)
                line.append(0x0A)
                try handle.write(contentsOf: line)
            } catch {
                log.error("write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Waits for all prior JSONL writes. Internal so the app test target can inspect a file
    /// only after its serial writer has finished.
    func flush() {
        queue.sync {}
    }

    private func scheduleEventScenarioCleanup(at expiresAt: Date) {
        let delay = max(0, expiresAt.timeIntervalSinceNow)
        cleanupQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.state.withLock { state in
                self.pruneExpiredEventScenarios(in: &state, now: .now)
            }
        }
    }

    private func pruneExpiredEventScenarios(in state: inout State, now: Date) {
        state.emittedEventScenarios = state.emittedEventScenarios.filter { $0.value.expiresAt > now }
    }
}

extension FieldTestRecorder.EventRecord {
    init(_ event: AnnouncementEvent) {
        self.init(
            id: event.id,
            text: event.text,
            priority: event.priority.rawValue,
            haptic: event.haptic?.rawValue,
            dedupKey: event.dedupKey,
            createdAt: event.createdAt,
            expiresAt: event.expiresAt
        )
    }
}

extension FieldTestRecorder.FrameRecord {
    init(
        analysis: ScenePerception.Analysis,
        diagnostics: ScenePerception.Diagnostics,
        frameTimestamp: TimeInterval,
        now: TimeInterval,
        tracking: String,
        cameraFPS: Double?
    ) {
        let observation = analysis.observation
        self.init(
            t: frameTimestamp,
            captureToResultMs: (now - frameTimestamp) * 1000,
            processingMs: analysis.processingMilliseconds,
            ocrBusy: analysis.wasReadingText,
            tracking: tracking,
            cameraFPS: cameraFPS,
            thermal: ProcessInfo.processInfo.thermalState.name,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            hasDepth: observation.hasMetricDepth,
            cameraHeight: diagnostics.cameraHeight,
            floorMeasured: diagnostics.isFloorMeasured,
            elevationScenarioID: nil,
            path: diagnostics.path?.clearDirection.rawValue,
            detections: observation.detections.map { detection in
                FieldTestRecorder.DetectionRecord(
                    label: detection.label,
                    origin: detection.origin.rawValue,
                    confidence: detection.confidence,
                    distance: detection.distance,
                    bearingDegrees: detection.bearing?.degrees,
                    track: detection.trackID.map { String($0.uuidString.prefix(8)) },
                    inPath: analysis.inPath.contains(detection.id)
                )
            },
            hazards: observation.elevationHazards.map {
                FieldTestRecorder.HazardRecord(type: $0.type.rawValue, distance: $0.distance, heightChange: $0.heightChange)
            },
            emitted: analysis.announcements.map(FieldTestRecorder.EventRecord.init),
            text: observation.recognizedText.map(\.string)
        )
    }
}

extension ProcessInfo.ThermalState {
    var name: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
