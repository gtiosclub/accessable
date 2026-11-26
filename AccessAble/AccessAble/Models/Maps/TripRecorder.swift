import Foundation
import Synchronization
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

    /// A trip's file taken from the recorder to finish, with the rows held for it and its battery logging to stop.
    private struct Taken {
        var file: FileHandle?
        var held: [Data] = []
        var batteryTask: Task<Void, Never>?
    }

    private struct State {
        var isEnabled = false
        var file: FileHandle?
        /// Rows written before the trip's first battery reading, held so that reading's row comes first.
        var heldRows: [Data]?
        var batteryTask: Task<Void, Never>?
        var lastError: String?

        mutating func takeFile() -> Taken {
            defer {
                file = nil
                heldRows = nil
                batteryTask = nil
            }
            return Taken(file: file, held: heldRows ?? [], batteryTask: batteryTask)
        }
    }

    /// How often a trip logs the battery between its start and end rows.
    static let batteryInterval: Duration = .seconds(60)

    static let header = "kind,time,latitude,longitude,horizontal_accuracy_m,location_source,speed_mps,course_deg,"
        + "course_accuracy_deg,heading_deg,heading_source,compass_accuracy_deg,progress_m,side_offset_m,next_step,"
        + "off_route,events,announcement"

    let directory: URL
    private let battery: any BatteryReading
    private let clock: any Clock<Duration>
    private let state = Mutex(State())

    init(directory: URL = .documentsDirectory.appending(path: "TripRecordings"),
         battery: any BatteryReading = DeviceBattery(), clock: any Clock<Duration> = ContinuousClock()) {
        self.directory = directory
        self.battery = battery
        self.clock = clock
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
        let taken = state.withLock { state in
            state.isEnabled = enabled
            return enabled ? Taken() : state.takeFile()
        }
        finish(taken)
    }

    /// Starts a new file for a trip, when recording is on.
    func tripStarted(at time: Date) {
        // a trip replacing one that never ended finishes that one's file, so rows never mix two trips
        finish(state.withLock { $0.takeFile() })
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
                state.heldRows = []
                state.lastError = nil
                state.batteryTask = Task { await self.logBattery(from: time, to: file) }
            }
        } catch {
            fail(error)
        }
    }

    /// Finishes the trip's file after a last battery row, which is read without making the trip wait: the file is
    /// taken at once, so a trip started meanwhile records to its own.
    /// - Returns: The task finishing the file, for a caller that reads it next.
    @discardableResult
    func tripEnded(at time: Date) -> Task<Void, Never> {
        let taken = state.withLock { $0.takeFile() }
        taken.batteryTask?.cancel()
        guard let file = taken.file else { return Task {} }
        write(taken.held, to: file)
        return Task {
            if let row = await batteryRow(at: time) { write([row], to: file) }
            close(file)
        }
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

    /// The recordings on this phone, newest first.
    func recordings() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path()) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "csv" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Deletes every recording, finishing the one being written first.
    func deleteRecordings() throws {
        finish(state.withLock { $0.takeFile() })
        for url in try recordings() {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// The battery when the trip started, before any other row, then every `batteryInterval` until the file is
    /// finished. Writes only to the trip's own file, so a reading that lands after it ended goes nowhere.
    private func logBattery(from start: Date, to file: FileHandle) async {
        var time = start
        while true {
            let row = await batteryRow(at: time)
            guard release(row, into: file) else { return }
            do { try await clock.sleep(for: Self.batteryInterval) } catch { return }
            time = .now
        }
    }

    /// Level as a percentage in the announcement column, and whether plugged in, which spoils a drain measurement,
    /// in events. Nil when the level is unknown, as on the simulator.
    private func batteryRow(at time: Date) async -> Data? {
        let status = await battery.status()
        guard let level = status.level else { return nil }
        return Self.line(["battery", Self.rowTime.format(time)] + Array(repeating: "", count: 14)
            + [status.isChargingOrFull ? "pluggedIn" : "unplugged", Self.format(Double(level) * 100)])
    }

    /// Writes `row`, then any rows held for it, while `file` is still the trip's.
    /// - Returns: Whether it is.
    private func release(_ row: Data?, into file: FileHandle) -> Bool {
        do {
            return try state.withLock { state in
                guard state.file === file else { return false }
                for line in [row].compactMap({ $0 }) + (state.heldRows ?? []) {
                    try file.write(contentsOf: line)
                }
                state.heldRows = nil
                return true
            }
        } catch {
            fail(error)
            return false
        }
    }

    /// Synchronous, under the lock: one short line a second or so, which is cheaper than a hop to another queue and
    /// keeps rows in the order they happened.
    private func write(_ fields: [String]) {
        guard isRecording else { return }
        let line = Self.line(fields)
        do {
            try state.withLock { state in
                if state.heldRows != nil {
                    state.heldRows?.append(line)
                } else {
                    try state.file?.write(contentsOf: line)
                }
            }
        } catch {
            fail(error)
        }
    }

    /// For a file taken from the recorder, which nothing else writes to now.
    private func write(_ rows: [Data], to file: FileHandle) {
        do {
            for line in rows { try file.write(contentsOf: line) }
        } catch {
            log.error("Trip recording's last rows weren't written: \(error.localizedDescription, privacy: .public)")
            state.withLock { $0.lastError = error.localizedDescription }
        }
    }

    /// Stops this file rather than the trip: guidance matters more than its record.
    private func fail(_ error: any Error) {
        log.error("Trip recording stopped: \(error.localizedDescription, privacy: .public)")
        let taken = state.withLock { state in
            state.lastError = error.localizedDescription
            return state.takeFile()
        }
        finish(taken)
    }

    private func finish(_ taken: Taken) {
        taken.batteryTask?.cancel()
        guard let file = taken.file else { return }
        write(taken.held, to: file)
        close(file)
    }

    private func close(_ file: FileHandle) {
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

    private static func line(_ fields: [String]) -> Data {
        Data((fields.map(escape).joined(separator: ",") + "\n").utf8)
    }

    /// RFC 4180: a field with a comma, quote or line break is quoted, with its quotes doubled.
    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
