import Foundation
import Testing
@testable import AccessAble

@Suite("Field-test recorder lifecycle", .serialized)
struct FieldTestRecorderTests {
    private let environment = FieldTestRecorder.TestEnvironment(tracking: "normal", thermal: "nominal")

    private func setup() -> FieldTestRecorder.ElevationSetup {
        .init(
            scenarioID: UUID(),
            physicalSetup: "entrance curb",
            surfaceType: "concrete",
            expectedHeight: 0.1,
            expectedDistance: 1,
            expectedHazard: "step / curb"
        )
    }

    private func frame(events: [FieldTestRecorder.EventRecord] = []) -> FieldTestRecorder.FrameRecord {
        .init(
            t: 1,
            captureToResultMs: 10,
            processingMs: 5,
            ocrBusy: false,
            tracking: "normal",
            cameraFPS: 60,
            thermal: "nominal",
            lowPower: false,
            hasDepth: true,
            cameraHeight: 1.4,
            floorMeasured: true,
            elevationScenarioID: nil,
            path: nil,
            detections: [],
            hazards: [],
            emitted: events,
            text: []
        )
    }

    private func records(at url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }

    @Test("a second setup is rejected without replacing the active scenario")
    func rejectsSetupReplacement() throws {
        let recorder = FieldTestRecorder()
        let url = try recorder.start()
        defer {
            recorder.stop()
            recorder.flush()
            try? FileManager.default.removeItem(at: url)
        }
        let first = setup()
        let second = setup()

        #expect(recorder.recordElevationSetup(first, environment: environment) == .recorded)
        #expect(recorder.recordElevationSetup(second, environment: environment) == .activeSetupExists)
        recorder.record(frame())
        #expect(recorder.recordElevationOutcome("tester heard warning", environment: environment) == .recorded)
        recorder.flush()

        let setupRecords = try records(at: url).filter { $0["kind"] as? String == "elevationSetup" }
        #expect(setupRecords.count == 1)
        let recordedSetup = setupRecords[0]["setup"] as? [String: Any]
        #expect(recordedSetup?["scenarioID"] as? String == first.scenarioID.uuidString)
    }

    @Test("an outcome requires a scenario-tagged analyzed frame")
    func rejectsOutcomeWithoutFrame() throws {
        let recorder = FieldTestRecorder()
        let url = try recorder.start()
        defer {
            recorder.stop()
            recorder.flush()
            try? FileManager.default.removeItem(at: url)
        }

        #expect(recorder.recordElevationSetup(setup(), environment: environment) == .recorded)
        #expect(recorder.recordElevationOutcome("inconclusive", environment: environment) == .noFramesRecorded)
    }

    @Test("frame write precedes its eligible outcome write")
    func writesFrameBeforeOutcome() throws {
        let recorder = FieldTestRecorder()
        let url = try recorder.start()
        defer {
            recorder.stop()
            recorder.flush()
            try? FileManager.default.removeItem(at: url)
        }

        #expect(recorder.recordElevationSetup(setup(), environment: environment) == .recorded)
        recorder.record(frame())
        #expect(recorder.recordElevationOutcome("tester heard warning", environment: environment) == .recorded)
        recorder.flush()

        let kinds = try records(at: url).compactMap { $0["kind"] as? String }
        #expect(kinds == ["elevationSetup", "frame", "elevationOutcome"])
    }

    @Test("late delivery remains attributed once, then its mapping is removed")
    func attributesLateDeliveryAndRemovesMapping() throws {
        let recorder = FieldTestRecorder()
        let url = try recorder.start()
        defer {
            recorder.stop()
            recorder.flush()
            try? FileManager.default.removeItem(at: url)
        }
        let scenario = setup()
        let event = AnnouncementEvent(
            category: .hazard,
            priority: .high,
            text: "Step ahead.",
            source: .obstacleDetection,
            expiresAt: .now.addingTimeInterval(30)
        )
        let eventRecord = FieldTestRecorder.EventRecord(event)

        #expect(recorder.recordElevationSetup(scenario, environment: environment) == .recorded)
        recorder.record(frame(events: [eventRecord]))
        #expect(recorder.recordElevationOutcome("tester heard warning", environment: environment) == .recorded)
        recorder.recordDelivered(event)
        recorder.recordDelivered(event)
        recorder.flush()

        let deliveries = try records(at: url).filter { $0["kind"] as? String == "delivered" }
        #expect(deliveries.count == 2)
        #expect(deliveries[0]["elevationScenarioID"] as? String == scenario.scenarioID.uuidString)
        #expect(deliveries[1]["elevationScenarioID"] == nil || deliveries[1]["elevationScenarioID"] is NSNull)
    }

    @Test("expired undelivered event mappings are not attributed")
    func expiresUndeliveredEventMapping() throws {
        let recorder = FieldTestRecorder()
        let url = try recorder.start()
        defer {
            recorder.stop()
            recorder.flush()
            try? FileManager.default.removeItem(at: url)
        }
        let event = AnnouncementEvent(
            category: .hazard,
            priority: .normal,
            text: "Old step.",
            source: .obstacleDetection,
            createdAt: .now.addingTimeInterval(-10),
            expiresAt: .now.addingTimeInterval(-2)
        )

        #expect(recorder.recordElevationSetup(setup(), environment: environment) == .recorded)
        recorder.record(frame(events: [FieldTestRecorder.EventRecord(event)]))
        recorder.recordDelivered(event)
        recorder.flush()

        let delivery = try #require(records(at: url).first { $0["kind"] as? String == "delivered" })
        #expect(delivery["elevationScenarioID"] == nil || delivery["elevationScenarioID"] is NSNull)
    }

    @Test("events without a declared lifetime are never retained for scenario attribution")
    func doesNotRetainEventWithoutExpiry() throws {
        let recorder = FieldTestRecorder()
        let url = try recorder.start()
        defer {
            recorder.stop()
            recorder.flush()
            try? FileManager.default.removeItem(at: url)
        }
        let event = AnnouncementEvent(
            category: .hazard,
            priority: .critical,
            text: "Stop.",
            source: .obstacleDetection
        )

        #expect(recorder.recordElevationSetup(setup(), environment: environment) == .recorded)
        recorder.record(frame(events: [FieldTestRecorder.EventRecord(event)]))
        recorder.recordDelivered(event)
        recorder.flush()

        let delivery = try #require(records(at: url).first { $0["kind"] as? String == "delivered" })
        #expect(delivery["elevationScenarioID"] == nil || delivery["elevationScenarioID"] is NSNull)
    }

    @Test("scenario status stream follows the recorder lifecycle")
    func publishesScenarioStatus() async throws {
        let recorder = FieldTestRecorder()
        var statuses = recorder.elevationScenarioStatuses().makeAsyncIterator()
        let url = try recorder.start()
        defer {
            recorder.stop()
            recorder.flush()
            try? FileManager.default.removeItem(at: url)
        }

        #expect(await statuses.next() == false)
        #expect(recorder.recordElevationSetup(setup(), environment: environment) == .recorded)
        #expect(await statuses.next() == true)
        recorder.record(frame())
        #expect(recorder.recordElevationOutcome("tester heard warning", environment: environment) == .recorded)
        #expect(await statuses.next() == false)
    }

    @Test("racing an outcome and replacement setup leaves status consistent with recorder state")
    func racesScenarioStatusUpdatesSafely() async throws {
        let recorder = FieldTestRecorder()
        var statuses = recorder.elevationScenarioStatuses().makeAsyncIterator()
        let url = try recorder.start()
        defer {
            recorder.stop()
            recorder.flush()
            try? FileManager.default.removeItem(at: url)
        }

        #expect(await statuses.next() == false)
        #expect(recorder.recordElevationSetup(setup(), environment: environment) == .recorded)
        #expect(await statuses.next() == true)
        recorder.record(frame())

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = recorder.recordElevationOutcome("tester heard warning", environment: self.environment)
            }
            group.addTask {
                _ = recorder.recordElevationSetup(self.setup(), environment: self.environment)
            }
        }

        #expect(await statuses.next() == recorder.hasActiveElevationSetup)
    }

    @Test("racing a frame and outcome never writes an outcome before its qualifying frame")
    func racesFrameAndOutcomeSafely() async throws {
        let recorder = FieldTestRecorder()
        let url = try recorder.start()
        defer {
            recorder.stop()
            recorder.flush()
            try? FileManager.default.removeItem(at: url)
        }

        #expect(recorder.recordElevationSetup(setup(), environment: environment) == .recorded)
        let firstOutcome = await withTaskGroup(of: FieldTestRecorder.ElevationOutcomeResult?.self, returning: FieldTestRecorder.ElevationOutcomeResult?.self) { group in
            group.addTask {
                recorder.record(self.frame())
                return nil
            }
            group.addTask {
                recorder.recordElevationOutcome("tester heard warning", environment: self.environment)
            }
            var outcome: FieldTestRecorder.ElevationOutcomeResult?
            for await result in group where result != nil { outcome = result }
            return outcome
        }
        if firstOutcome == .noFramesRecorded {
            #expect(recorder.recordElevationOutcome("tester heard warning", environment: environment) == .recorded)
        } else {
            #expect(firstOutcome == .recorded)
        }
        recorder.flush()

        let kinds = try records(at: url).compactMap { $0["kind"] as? String }
        #expect(kinds == ["elevationSetup", "frame", "elevationOutcome"])
    }

    @Test("racing delivery and outcome retains the delivery's originating scenario")
    func racesDeliveryAndOutcomeSafely() async throws {
        let recorder = FieldTestRecorder()
        let url = try recorder.start()
        defer {
            recorder.stop()
            recorder.flush()
            try? FileManager.default.removeItem(at: url)
        }
        let scenario = setup()
        let event = AnnouncementEvent(
            category: .hazard,
            priority: .high,
            text: "Step ahead.",
            source: .obstacleDetection,
            expiresAt: .now.addingTimeInterval(30)
        )

        #expect(recorder.recordElevationSetup(scenario, environment: environment) == .recorded)
        recorder.record(frame(events: [FieldTestRecorder.EventRecord(event)]))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { recorder.recordDelivered(event) }
            group.addTask { _ = recorder.recordElevationOutcome("tester heard warning", environment: self.environment) }
        }
        recorder.flush()

        let delivery = try #require(records(at: url).first { $0["kind"] as? String == "delivered" })
        #expect(delivery["elevationScenarioID"] as? String == scenario.scenarioID.uuidString)
    }
}
