import Foundation
import Testing
@testable import AccessAble

/// A recorder writing to its own temporary folder, removed afterwards. The battery's level is unknown unless given,
/// so it writes no battery rows.
private func withRecorder(battery: any BatteryReading = FakeBattery(level: nil), clock: ManualClock = ManualClock(),
                          _ body: (TripRecorder) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "TripRecorderTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(TripRecorder(directory: directory, battery: battery, clock: clock))
}

private func lines(of url: URL) throws -> [String] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
}

private let start = TripWalk.start

struct TripRecorderTests {
    @Test
    func isOffByDefaultAndWritesNothing() async throws {
        try await withRecorder { recorder in
            #expect(!recorder.isEnabled)
            recorder.tripStarted(at: start)
            #expect(!recorder.isRecording)
            let recordings = try recorder.recordings()
            #expect(recordings.isEmpty)
        }
    }

    @Test
    func writesAFixAndAnAnnouncementAsCSVRows() async throws {
        try await withRecorder { recorder in
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
            await recorder.tripEnded(at: start).value
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
    func turningOffFinishesTheFileAndEachTripStartsANewOne() async throws {
        try await withRecorder { recorder in
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
    func keepsRecordingsOutOfBackups() async throws {
        try await withRecorder { recorder in
            recorder.setEnabled(true)
            recorder.tripStarted(at: start)
            let values = try recorder.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true)
        }
    }

    @Test
    func deletingFinishesTheFileBeingWrittenAndRemovesEveryRecording() async throws {
        try await withRecorder { recorder in
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
    func logsTheBatteryFirstAndLastWithWhetherPluggedIn() async throws {
        let clock = ManualClock()
        let battery = FakeBattery(level: 0.85)
        try await withRecorder(battery: battery, clock: clock) { recorder in
            recorder.setEnabled(true)
            recorder.tripStarted(at: start)
            // before the first reading is in, so held for it
            recorder.record(announcement: "Starting directions.", at: start)
            try await clock.waitForSleepers(1)
            battery.set(level: 0.83, isChargingOrFull: true)
            await recorder.tripEnded(at: start.addingTimeInterval(30)).value

            let rows = try lines(of: try #require(try recorder.recordings().first))
            #expect(rows == [
                TripRecorder.header,
                "battery,2023-11-14T22:13:20.000Z,,,,,,,,,,,,,,,unplugged,85.0",
                "announcement,2023-11-14T22:13:20.000Z,,,,,,,,,,,,,,,,Starting directions.",
                "battery,2023-11-14T22:13:50.000Z,,,,,,,,,,,,,,,pluggedIn,83.0",
            ])
            let columns = TripRecorder.header.split(separator: ",").count
            for row in rows where row.hasPrefix("battery,") {
                #expect(row.split(separator: ",", omittingEmptySubsequences: false).count == columns)
            }
        }
    }

    @Test
    func logsTheBatteryEveryMinute() async throws {
        let clock = ManualClock()
        let battery = FakeBattery(level: 0.9)
        try await withRecorder(battery: battery, clock: clock) { recorder in
            recorder.setEnabled(true)
            recorder.tripStarted(at: start)
            try await clock.waitForSleepers(1)
            battery.set(level: 0.89)
            clock.advance(by: TripRecorder.batteryInterval)
            try await clock.waitForSleepers(1)
            battery.set(level: 0.88)
            clock.advance(by: TripRecorder.batteryInterval)
            try await clock.waitForSleepers(1)
            await recorder.tripEnded(at: start).value

            let rows = try lines(of: try #require(try recorder.recordings().first)).filter { $0.hasPrefix("battery,") }
            #expect(rows.map { $0.split(separator: ",").last } == ["90.0", "89.0", "88.0", "88.0"])
        }
    }

    @Test
    func batteryLoggingStopsWhenRecordingTurnsOff() async throws {
        let clock = ManualClock()
        let battery = FakeBattery(level: 0.75)
        try await withRecorder(battery: battery, clock: clock) { recorder in
            recorder.setEnabled(true)
            recorder.tripStarted(at: start)
            try await clock.waitForSleepers(1)

            recorder.setEnabled(false)
            // the next reading's wait is cancelled, so no advance can wake it
            #expect(clock.sleeperCount == 0)
            clock.advance(by: TripRecorder.batteryInterval)

            #expect(battery.reads == 1)
            let rows = try lines(of: try #require(try recorder.recordings().first))
            #expect(rows.filter { $0.hasPrefix("battery,") }.count == 1)
        }
    }

    @Test
    func aReadingThatLandsAfterItsTripGoesNowhere() async throws {
        let clock = ManualClock()
        let battery = BlockingBattery(level: 0.5, blockingRead: 1)
        try await withRecorder(battery: battery, clock: clock) { recorder in
            recorder.setEnabled(true)
            recorder.tripStarted(at: start)
            while !battery.isBlocked { await Task.yield() }
            recorder.tripStarted(at: start.addingTimeInterval(60))
            try await clock.waitForSleepers(1)
            battery.release()
            // the first trip's logging, if it went on, would write into the second trip's file and wait again
            for _ in 0..<100 { await Task.yield() }
            await recorder.tripEnded(at: start.addingTimeInterval(90)).value

            let recordings = try recorder.recordings()
            #expect(recordings.count == 2)
            #expect(try lines(of: recordings[0]).filter { $0.hasPrefix("battery,") }.count == 2)
            #expect(try lines(of: recordings[1]) == [TripRecorder.header])
            #expect(clock.sleeperCount == 0)
        }
    }
}
