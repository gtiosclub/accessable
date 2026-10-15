import Foundation
import Synchronization
import os

/// Owner: Computer Vision (1.4). Records what the pipeline saw and said, frame by frame,
/// during an on-device test walk, so the device validation checklist can be checked
/// against data rather than by watching the screen.
///
/// Each recording is one JSON Lines file in `Documents/FieldTests/`, one object per line:
/// `{"kind":"frame",…}` for every analyzed frame, `{"kind":"delivered",…}` for every
/// announcement the engine delivered, and `{"kind":"mark",…}` when the tester marks a
/// checklist step. Copy them off the phone with
/// `xcrun devicectl device copy from --domain-type appDataContainer …`.
///
/// Recording is off by default and `record` returns immediately while it is off, so the
/// recorder can sit in the live pipeline permanently. Writes happen on a utility queue,
/// never on the analysis queue.
final class FieldTestRecorder: Sendable {
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
        let text: String
        let priority: Int
        let haptic: String?
        let dedupKey: String?
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
        let detections: [DetectionRecord]
        let hazards: [HazardRecord]
        let emitted: [EventRecord]
        let text: [String]
    }

    private struct DeliveredRecord: Codable {
        var kind = "delivered"
        let t: TimeInterval
        let event: EventRecord
    }

    private struct MarkRecord: Codable {
        var kind = "mark"
        let t: TimeInterval
        let label: String
    }

    private struct State {
        var handle: FileHandle?
        var url: URL?
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "AccessAble.FieldTestRecorder", qos: .utility)
    private let log = Logger(subsystem: "AccessAble", category: "FieldTestRecorder")

    var isRecording: Bool { state.withLock { $0.handle != nil } }

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
            return state.handle
        }
        queue.async { try? previous?.close() }
        log.notice("recording to \(url.lastPathComponent, privacy: .public)")
        return url
    }

    func stop() {
        let handle = state.withLock { state in
            defer { state = State() }
            return state.handle
        }
        queue.async { try? handle?.close() }
    }

    /// Marks the moment a checklist step starts, e.g. "chair 2 m ahead".
    func mark(_ label: String) {
        write(MarkRecord(t: ProcessInfo.processInfo.systemUptime, label: label))
    }

    func record(_ frame: @autoclosure () -> FrameRecord) {
        guard isRecording else { return }
        write(frame())
    }

    func recordDelivered(_ event: AnnouncementEvent) {
        guard isRecording else { return }
        write(DeliveredRecord(t: ProcessInfo.processInfo.systemUptime, event: EventRecord(event)))
    }

    private func write(_ record: some Encodable & Sendable) {
        guard let handle = state.withLock({ $0.handle }) else { return }
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
}

extension FieldTestRecorder.EventRecord {
    init(_ event: AnnouncementEvent) {
        self.init(
            text: event.text,
            priority: event.priority.rawValue,
            haptic: event.haptic?.rawValue,
            dedupKey: event.dedupKey
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

private extension ProcessInfo.ThermalState {
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
