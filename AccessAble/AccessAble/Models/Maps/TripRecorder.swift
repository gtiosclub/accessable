import Foundation
import Synchronization
import UIKit
import os

private let log = Logger(subsystem: "AccessAble", category: "TripRecorder")

/// Owner: Maps (2.x). Records each trip fix by fix to a CSV file, so a field walk can be checked against what the
/// guidance decided: where each fix put the user and how precisely, which way they were taken to face, how far along
/// and how far off the route the tracker placed them, and what was said.
///
/// Off by default and at every launch. While it is off, `isRecording` is false and `TripManager` builds no rows, so
/// it costs nothing. A file is started when a trip starts and finished when it ends or arrives. Files stay on this
/// phone, in `Documents/TripRecordings/`, which is kept out of backups, until the user shares or deletes them.
final class TripRecorder: Sendable {
    /// What one location fix did to the trip.
    struct Fix: Sendable {
        var sample: LocationSample
        var heading: UserHeading?
        /// Degrees; the latest compass reading's, whether or not it was used.
        var compassAccuracy: Double?
        /// Metres along the route of accepted progress.
        var progress: Double
        /// Metres from the route as the tracker measured the fix, negative left; nil when it ignored the fix.
        var sideOffset: Double?
        var nextStepIndex: Int
        var isOffRoute: Bool
        var events: [RouteProgressTracker.GuidanceEvent]
    }

    private struct State {
        var isEnabled = false
        var file: FileHandle?
        var lastError: String?
        var batteryTask: Task<Void, Never>?
    }

    static let header = "kind,time,latitude,longitude,horizontal_accuracy_m,location_source,speed_mps,course_deg,"
        + "course_accuracy_deg,heading_deg,heading_source,compass_accuracy_deg,progress_m,side_offset_m,next_step,"
        + "off_route,events,announcement"

    let directory: URL
    private let batteryReader: @Sendable () async -> Float?
    private let clock: any Clock<Duration> & Sendable
    private let state = Mutex(State())

    init(
        directory: URL = .documentsDirectory.appending(path: "TripRecordings"),
        batteryReader: (@Sendable () async -> Float?)? = nil,
        clock: (any Clock<Duration> & Sendable)? = nil
    ) {
        self.directory = directory
        self.batteryReader = batteryReader ?? {
            await MainActor.run {
                UIDevice.current.isBatteryMonitoringEnabled = true
                let level = UIDevice.current.batteryLevel
                return level < 0 ? nil : level * 100
            }
        }
        self.clock = clock ?? ContinuousClock()
    }

    var isEnabled: Bool {
        state.withLock { $0.isEnabled }
    }

    /// On and with a trip's file open, so rows are wanted.
    var isRecording: Bool {
        state.withLock { $0.file != nil }
    }

    /// Why the last file couldn't be started or written, until the next one starts.
    var lastError: String? {
        state.withLock { $0.lastError }
    }

    /// Turning it off finishes the file being written; turning it on records from the next trip.
    func setEnabled(_ enabled: Bool) {
        let (file, task) = state.withLock { state -> (FileHandle?, Task<Void, Never>?) in
            state.isEnabled = enabled
            guard !enabled else { return (nil, nil) }
            let t = state.batteryTask
            state.batteryTask = nil
            defer { state.file = nil }
            return (state.file, t)
        }
        task?.cancel()
        close(file)
    }

    /// Starts a new file for a trip, when recording is on.
    func tripStarted(at time: Date) {
        // a trip replacing one that never ended finishes that one's file, so rows never mix two trips
        let (previous, previousTask) = state.withLock { state -> (FileHandle?, Task<Void, Never>?) in
            let t = state.batteryTask
            state.batteryTask = nil
            defer { state.file = nil }
            return (state.file, t)
        }
        previousTask?.cancel()
        close(previous)
        guard isEnabled else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // location history mustn't leave the phone in an iCloud or computer backup
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = directory
            try excluded.setResourceValues(values)
            let name = "trip-" + Self.fileTime.format(time).replacingOccurrences(of: ":", with: "-") + ".csv"
            let url = directory.appending(path: name)
            guard FileManager.default.createFile(atPath: url.path(), contents: Data((Self.header + "\n").utf8)) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path()])
            }
            let file = try FileHandle(forWritingTo: url)
            try file.seekToEnd()
            state.withLock { state in
                state.file = file
                state.lastError = nil
                state.batteryTask = Task { [weak self] in
                    guard let self else { return }
                    await runBatteryLoop(startTime: time)
                }
            }
        } catch {
            fail(error)
        }
    }

    func tripEnded() async {
        let task = state.withLock { state -> Task<Void, Never>? in
            let t = state.batteryTask
            state.batteryTask = nil
            return t
        }
        task?.cancel()
        if let pct = await batteryReader() {
            record(battery: pct, at: Date())
        }
        let file = state.withLock { state -> FileHandle? in
            defer { state.file = nil }
            return state.file
        }
        close(file)
    }

    func record(_ fix: Fix) {
        let sample = fix.sample
        write([
            "fix", Self.rowTime.format(sample.timestamp),
            Self.format(sample.coordinate.latitude, digits: 7), Self.format(sample.coordinate.longitude, digits: 7),
            Self.format(sample.horizontalAccuracy), sample.source.rawValue, Self.format(sample.speed),
            Self.format(sample.course), Self.format(sample.courseAccuracy), Self.format(fix.heading?.degrees),
            fix.heading?.source.rawValue ?? "",
            Self.format(fix.compassAccuracy), Self.format(fix.progress), Self.format(fix.sideOffset),
            String(fix.nextStepIndex), fix.isOffRoute ? "1" : "0",
            fix.events.map(Self.describe).joined(separator: " "), "",
        ])
    }

    /// Everything the trip submits to the announcement engine, whether or not it was then spoken.
    func record(announcement text: String, at time: Date) {
        write(["announcement", Self.rowTime.format(time)] + Array(repeating: "", count: 15) + [text])
    }

    /// A sign the camera read, matched or not, so a walk's missed buildings can be told from its misreads (LAND-5).
    /// The text goes in the announcement column, and its kind and confidence in events.
    func record(sighting: LandmarkObservation, progress: Double, at time: Date) {
        write(["sighting", Self.rowTime.format(time)] + Array(repeating: "", count: 10)
            + [Self.format(progress), "", "", "", "\(sighting.kind.rawValue) \(Self.format(Double(sighting.confidence), digits: 2))",
               sighting.text ?? ""])
    }

    /// Battery level sampled at trip start, once a minute, and at trip end. Percent (0–100) in the announcement
    /// column; the `battery` kind distinguishes it from spoken text.
    func record(battery percent: Float, at time: Date) {
        write(["battery", Self.rowTime.format(time)] + Array(repeating: "", count: 15)
            + [Self.format(Double(percent))])
    }

    /// The recordings on this phone, newest first.
    func recordings() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path()) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "csv" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Deletes every recording, finishing the one being written first.
    func deleteRecordings() throws {
        closeCurrent()
        for url in try recordings() {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func closeCurrent() {
        let (file, task) = state.withLock { state -> (FileHandle?, Task<Void, Never>?) in
            let t = state.batteryTask
            state.batteryTask = nil
            defer { state.file = nil }
            return (state.file, t)
        }
        task?.cancel()
        close(file)
    }

    private func runBatteryLoop(startTime: Date) async {
        if let pct = await batteryReader() {
            record(battery: pct, at: startTime)
        }
        do {
            while true {
                try await clock.sleep(for: .seconds(60))
                if let pct = await batteryReader() {
                    record(battery: pct, at: Date())
                }
            }
        } catch {
            // Task cancelled — loop ended normally
        }
    }

    /// Synchronous, under the lock: one short line a second or so, which is cheaper than a hop to another queue and
    /// keeps rows in the order they happened.
    private func write(_ fields: [String]) {
        guard isRecording else { return }
        let line = Data((fields.map(Self.escape).joined(separator: ",") + "\n").utf8)
        do {
            try state.withLock { state in try state.file?.write(contentsOf: line) }
        } catch {
            fail(error)
        }
    }

    /// Stops this file rather than the trip: guidance matters more than its record.
    private func fail(_ error: any Error) {
        log.error("Trip recording stopped: \(error.localizedDescription, privacy: .public)")
        let file = state.withLock { state -> FileHandle? in
            state.lastError = error.localizedDescription
            defer { state.file = nil }
            return state.file
        }
        close(file)
    }

    private func close(_ file: FileHandle?) {
        guard let file else { return }
        do {
            try file.close()
        } catch {
            log.error("Trip recording didn't close: \(error.localizedDescription, privacy: .public)")
            state.withLock { $0.lastError = error.localizedDescription }
        }
    }

    private static let rowTime = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let fileTime = Date.ISO8601FormatStyle()

    private static func format(_ value: Double?, digits: Int = 1) -> String {
        guard let value else { return "" }
        return value.formatted(.number.precision(.fractionLength(digits)).grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX")))
    }

    private static func describe(_ event: RouteProgressTracker.GuidanceEvent) -> String {
        switch event {
        case let .prepare(step, distance): "prepare(\(step),\(format(distance)))"
        case let .now(step): "now(\(step))"
        case let .passedTurnConfirmation(step): "passedTurn(\(step))"
        case let .missedTurn(step, distance): "missedTurn(\(step),\(format(distance)))"
        case let .crossing(index): "crossing(\(index))"
        case .wrongWay: "wrongWay"
        case .offRoute: "offRoute"
        case .backOnRoute: "backOnRoute"
        case .arrived: "arrived"
        }
    }

    /// RFC 4180: a field with a comma, quote or line break is quoted, with its quotes doubled.
    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
