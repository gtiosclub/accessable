import Foundation
import Synchronization
import Testing
@testable import AccessAble

/// Thread-safe mutable Float for injecting battery readings that change mid-test.
private final class BatterySource: @unchecked Sendable {
    private let mutex: Mutex<Float>
    init(_ value: Float) { mutex = Mutex(value) }
    var value: Float { mutex.withLock { $0 } }
    func set(_ v: Float) { mutex.withLock { $0 = v } }
}

/// A recorder writing to its own temporary folder, removed afterwards.
private func withRecorder(_ body: (TripRecorder) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "TripRecorderTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(TripRecorder(directory: directory))
}

/// Async variant with injectable battery reader and clock.
private func withRecorder(
    batteryReader: (@Sendable () async -> Float?)? = nil,
    clock: (any Clock<Duration> & Sendable)? = nil,
    _ body: (TripRecorder) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "TripRecorderTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(TripRecorder(directory: directory, batteryReader: batteryReader, clock: clock))
}

private func lines(of url: URL) throws -> [String] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
}

private let start = TripWalk.start

struct TripRecorderTests {
    @Test
    func isOffByDefaultAndWritesNothing() throws {
        try withRecorder { recorder in
            #expect(!recorder.isEnabled)
            recorder.tripStarted(at: start)
            #expect(!recorder.isRecording)
            let recordings = try recorder.recordings()
            #expect(recordings.isEmpty)
        }
    }

    @Test
    func writesAFixAndAnAnnouncementAsCSVRows() async throws {
        // Nil battery reader so no battery rows appear; the test asserts the exact row list.
        try await withRecorder(batteryReader: { nil }) { recorder in
            recorder.setEnabled(true)
            recorder.tripStarted(at: start)
            #expect(recorder.isRecording)
            let sample = LocationSample(coordinate: GeoCoordinate(latitude: 33.775, longitude: -84.399),
                                        horizontalAccuracy: 6.26, timestamp: start, speed: 1.4, course: 271.5,
                                        courseAccuracy: 20, source: .ar)
            recorder.record(TripRecorder.Fix(
                sample: sample, heading: UserHeading(degrees: 271.5, source: .walkingDirection, timestamp: start),
                compassAccuracy: 15, progress: 49.4, sideOffset: -21.04, nextStepIndex: 1, isOffRoute: true,
                events: [.offRoute, .prepare(step: 2, distance: 39.96)]
            ))
            recorder.record(announcement: "You're off the route. Finding a new route.", at: start)
            recorder.record(announcement: "Say \"stop\", then wait", at: start)
            recorder.record(sighting: LandmarkObservation(kind: .signText, text: "JOHN LEWIS STUDENT CENTER", key: "sign",
                                                          confidence: 0.876),
                            progress: 98.26, at: start)
            await recorder.tripEnded()
            #expect(!recorder.isRecording)

            let url = try #require(try recorder.recordings().first)
            #expect(url.lastPathComponent == "trip-2023-11-14T22-13-20Z.csv")
            let rows = try lines(of: url)
            #expect(rows == [
                TripRecorder.header,
                "fix,2023-11-14T22:13:20.000Z,33.7750000,-84.3990000,6.3,ar,1.4,271.5,20.0,271.5,walkingDirection,15.0,"
                    + "49.4,-21.0,1,1,\"offRoute prepare(2,40.0)\",",
                "announcement,2023-11-14T22:13:20.000Z,,,,,,,,,,,,,,,,You're off the route. Finding a new route.",
                "announcement,2023-11-14T22:13:20.000Z,,,,,,,,,,,,,,,,\"Say \"\"stop\"\", then wait\"",
                "sighting,2023-11-14T22:13:20.000Z,,,,,,,,,,,98.3,,,,signText 0.88,JOHN LEWIS STUDENT CENTER",
            ])
        }
    }

    @Test
    func turningOffFinishesTheFileAndEachTripStartsANewOne() throws {
        try withRecorder { recorder in
            recorder.setEnabled(true)
            recorder.tripStarted(at: start)
            recorder.tripStarted(at: start.addingTimeInterval(60))
            recorder.record(announcement: "Trip ended.", at: start.addingTimeInterval(61))
            recorder.setEnabled(false)
            #expect(!recorder.isRecording)
            recorder.record(announcement: "Not recorded.", at: start.addingTimeInterval(62))

            let recordings = try recorder.recordings()
            #expect(recordings.map(\.lastPathComponent) == ["trip-2023-11-14T22-14-20Z.csv",
                                                            "trip-2023-11-14T22-13-20Z.csv"])
            let newer = try lines(of: recordings[0])
            let older = try lines(of: recordings[1])
            #expect(newer.count == 2)
            #expect(older == [TripRecorder.header])
        }
    }

    @Test
    func keepsRecordingsOutOfBackups() throws {
        try withRecorder { recorder in
            recorder.setEnabled(true)
            recorder.tripStarted(at: start)
            let values = try recorder.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true)
        }
    }

    @Test
    func deletingFinishesTheFileBeingWrittenAndRemovesEveryRecording() throws {
        try withRecorder { recorder in
            recorder.setEnabled(true)
            recorder.tripStarted(at: start)
            recorder.tripStarted(at: start.addingTimeInterval(60))
            try recorder.deleteRecordings()

            #expect(!recorder.isRecording)
            let recordings = try recorder.recordings()
            #expect(recordings.isEmpty)
            // still on, so the next trip records again
            recorder.tripStarted(at: start.addingTimeInterval(120))
            let next = try recorder.recordings()
            #expect(next.count == 1)
        }
    }

    @Test
    func batteryLoggingWritesRowAtTripStartAndEnd() async throws {
        let clock = ManualClock()
        let battery = BatterySource(85)
        try await withRecorder(batteryReader: { battery.value }, clock: clock) { recorder in
            recorder.setEnabled(true)
            recorder.tripStarted(at: start)
            // Wait until the loop has written the start sample and is sleeping on its 60s interval.
            try await clock.waitForSleepers(1)

            battery.set(83)
            await recorder.tripEnded()

            let url = try #require(try recorder.recordings().first)
            let rows = try lines(of: url)
            let batteryRows = rows.filter { $0.hasPrefix("battery,") }
            // Start sample (85) and end sample (83).
            #expect(batteryRows.count == 2)
            #expect(batteryRows[0].hasSuffix(",85.0") == true)
            #expect(batteryRows[1].hasSuffix(",83.0") == true)
        }
    }

    @Test
    func batteryLoggingWritesPeriodicSampleEvery60Seconds() async throws {
        let clock = ManualClock()
        let battery = BatterySource(90)
        try await withRecorder(batteryReader: { battery.value }, clock: clock) { recorder in
            recorder.setEnabled(true)
            recorder.tripStarted(at: start)
            // Wait until the loop is sleeping on its 60s interval.
            try await clock.waitForSleepers(1)

            // Advance 60s → second sample.
            battery.set(89)
            clock.advance(by: .seconds(60))
            // Wait for the task to write the sample and go back to sleep.
            try await clock.waitForSleepers(1)

            // Advance another 60s → third sample.
            battery.set(88)
            clock.advance(by: .seconds(60))
            try await clock.waitForSleepers(1)

            await recorder.tripEnded()

            let url = try #require(try recorder.recordings().first)
            let rows = try lines(of: url)
            let batteryRows = rows.filter { $0.hasPrefix("battery,") }
            // start (90) + two periodic (89, 88) + end (88 — same as last tick).
            #expect(batteryRows.count == 4)
            #expect(batteryRows[0].hasSuffix(",90.0") == true)
            #expect(batteryRows[1].hasSuffix(",89.0") == true)
            #expect(batteryRows[2].hasSuffix(",88.0") == true)
        }
    }

    @Test
    func batteryLoggingStopsWhenRecordingTurnsOff() async throws {
        let clock = ManualClock()
        try await withRecorder(batteryReader: { 75 }, clock: clock) { recorder in
            recorder.setEnabled(true)
            recorder.tripStarted(at: start)
            try await clock.waitForSleepers(1)

            recorder.setEnabled(false)
            // After turning off, advancing the clock must not write any new rows.
            clock.advance(by: .seconds(60))

            let recordings = try recorder.recordings()
            #expect(recordings.count == 1)
            let rows = try lines(of: recordings[0])
            let batteryRows = rows.filter { $0.hasPrefix("battery,") }
            // Only the start sample; loop was cancelled before the tick.
            #expect(batteryRows.count == 1)
        }
    }

    @Test
    func nilBatteryReaderWritesNoBatteryRows() async throws {
        try await withRecorder(batteryReader: { nil }) { recorder in
            recorder.setEnabled(true)
            recorder.tripStarted(at: start)
            await recorder.tripEnded()

            let url = try #require(try recorder.recordings().first)
            let rows = try lines(of: url)
            #expect(rows.filter { $0.hasPrefix("battery,") }.isEmpty)
        }
    }
}
