import Foundation
import Testing
@testable import AccessAble

private actor RecordingSink: AnnouncementSink {
    private(set) var submitted: [AnnouncementEvent] = []

    func submit(_ event: AnnouncementEvent) async {
        submitted.append(event)
    }

    var texts: [String] { submitted.map(\.text) }
}

private struct Rig {
    let clock = ManualClock()
    let battery: FakeBattery
    let sink = RecordingSink()
    let monitor: BatteryMonitor

    init(level: Float?, isChargingOrFull: Bool = false) {
        battery = FakeBattery(level: level, isChargingOrFull: isChargingOrFull)
        monitor = BatteryMonitor(battery: battery, announcements: sink, clock: clock)
    }

    /// Starts watching and waits for the first check, which ends in the wait for the next.
    func start() async throws {
        monitor.start()
        try await clock.waitForSleepers(1)
    }

    /// Moves on to the next check and waits for it to finish.
    func tick() async throws {
        clock.advance(by: BatteryMonitor.checkInterval)
        try await clock.waitForSleepers(1)
    }
}

private let low18 = "Battery is low, 18 percent."
private let veryLow9 = "Battery is very low, 9 percent. Turning off the camera view saves power."

// a check that never finishes fails the test instead of hanging the run
@Suite(.timeLimit(.minutes(1)))
struct BatteryMonitorTests {
    @Test
    func staysQuietAbove20Percent() async throws {
        let rig = Rig(level: 0.25)
        try await rig.start()
        try await rig.tick()

        #expect(rig.battery.reads == 2)
        #expect(await rig.sink.submitted.isEmpty)
    }

    @Test
    func warnsOnceOnDroppingBelow20Percent() async throws {
        let rig = Rig(level: 0.25)
        try await rig.start()
        rig.battery.set(level: 0.18)
        try await rig.tick()
        try await rig.tick()
        try await rig.tick()

        #expect(rig.battery.reads == 4)
        let warnings = await rig.sink.submitted
        #expect(warnings.map(\.text) == [low18])
        #expect(warnings.first?.category == .system)
        #expect(warnings.first?.priority == .high)
        #expect(warnings.first?.dedupKey == "battery-20")
    }

    @Test
    func warnsAgainOnDroppingBelow10Percent() async throws {
        let rig = Rig(level: 0.18)
        try await rig.start()
        rig.battery.set(level: 0.09)
        try await rig.tick()
        try await rig.tick()

        let warnings = await rig.sink.submitted
        #expect(warnings.map(\.text) == [low18, veryLow9])
        #expect(warnings.last?.category == .system)
        #expect(warnings.last?.priority == .high)
        #expect(warnings.last?.dedupKey == "battery-10")
    }

    @Test
    func startingBelow10PercentGivesOnlyThatWarning() async throws {
        let rig = Rig(level: 0.08)
        try await rig.start()
        rig.battery.set(level: 0.05)
        try await rig.tick()

        #expect(await rig.sink.texts == [
            "Battery is very low, 8 percent. Turning off the camera view saves power.",
        ])
    }

    @Test
    func unknownLevelSaysNothing() async throws {
        let rig = Rig(level: nil)
        try await rig.start()
        try await rig.tick()

        #expect(rig.battery.reads == 2)
        #expect(await rig.sink.submitted.isEmpty)
    }

    @Test
    func pluggedInSaysNothingUntilUnplugged() async throws {
        let rig = Rig(level: 0.05, isChargingOrFull: true)
        try await rig.start()
        try await rig.tick()
        #expect(rig.battery.reads == 2)
        #expect(await rig.sink.submitted.isEmpty)

        rig.battery.set(level: 0.09)
        try await rig.tick()
        #expect(await rig.sink.texts == [veryLow9])
    }

    @Test
    func pausedSkipsChecks() async throws {
        let rig = Rig(level: 0.25)
        try await rig.start()
        rig.monitor.setPaused(true)
        rig.battery.set(level: 0.09)
        try await rig.tick()
        #expect(rig.battery.reads == 1)
        #expect(await rig.sink.submitted.isEmpty)

        rig.monitor.setPaused(false)
        try await rig.tick()
        #expect(await rig.sink.texts == [veryLow9])
    }

    @Test
    func stopEndsChecks() async throws {
        let rig = Rig(level: 0.25)
        try await rig.start()
        rig.monitor.stop()
        rig.battery.set(level: 0.09)
        rig.clock.advance(by: BatteryMonitor.checkInterval)
        rig.clock.advance(by: BatteryMonitor.checkInterval)

        #expect(rig.battery.reads == 1)
        #expect(await rig.sink.submitted.isEmpty)
    }

    @Test
    func aNewTripWarnsAgain() async throws {
        let rig = Rig(level: 0.18)
        try await rig.start()
        rig.monitor.stop()
        try await rig.start()

        #expect(await rig.sink.texts == [low18, low18])
    }
}
