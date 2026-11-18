import Foundation
import Testing
@testable import AccessAble

/// A recorder writing to its own temporary folder, removed afterwards.
private func withRecorder(_ body: (TripRecorder) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "TripRecorderTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(TripRecorder(directory: directory))
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
    func writesAFixAndAnAnnouncementAsCSVRows() throws {
        try withRecorder { recorder in
            recorder.setEnabled(true)
            recorder.tripStarted(at: start)
            #expect(recorder.isRecording)
            let sample = LocationSample(coordinate: GeoCoordinate(latitude: 33.775, longitude: -84.399),
                                        horizontalAccuracy: 6.26, timestamp: start, speed: 1.4, course: 271.5,
                                        courseAccuracy: 20)
            recorder.record(TripRecorder.Fix(
                sample: sample, heading: UserHeading(degrees: 271.5, source: .walkingDirection, timestamp: start),
                compassAccuracy: 15, progress: 49.4, sideOffset: -21.04, nextStepIndex: 1, isOffRoute: true,
                events: [.offRoute, .prepare(step: 2, distance: 39.96)]
            ))
            recorder.record(announcement: "You're off the route. Finding a new route.", at: start)
            recorder.record(announcement: "Say \"stop\", then wait", at: start)
            recorder.tripEnded()
            #expect(!recorder.isRecording)

            let url = try #require(try recorder.recordings().first)
            #expect(url.lastPathComponent == "trip-2023-11-14T22-13-20Z.csv")
            let rows = try lines(of: url)
            #expect(rows == [
                TripRecorder.header,
                "fix,2023-11-14T22:13:20.000Z,33.7750000,-84.3990000,6.3,1.4,271.5,20.0,271.5,walkingDirection,15.0,"
                    + "49.4,-21.0,1,1,\"offRoute prepare(2,40.0)\",",
                "announcement,2023-11-14T22:13:20.000Z,,,,,,,,,,,,,,,You're off the route. Finding a new route.",
                "announcement,2023-11-14T22:13:20.000Z,,,,,,,,,,,,,,,\"Say \"\"stop\"\", then wait\"",
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
}
