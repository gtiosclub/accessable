import Foundation
import Testing
@testable import AccessAble

/// Records the monitor's warnings, reporting each as delivered unless set not to, as the engine drops some.
private actor WarningSink {
    private(set) var warnings: [BatteryMonitor.Warning] = []
    private var delivers = true

    func receive(_ warning: BatteryMonitor.Warning, from monitor: BatteryMonitor) {
        warnings.append(warning)
        if delivers { monitor.delivered(warning.level) }
    }

    func setDelivers(_ value: Bool) {
        delivers = value
    }

    var texts: [String] { warnings.map(\.text) }
}

private struct Rig {
    let clock = ManualClock()
    let battery: FakeBattery
    let sink = WarningSink()
    let monitor: BatteryMonitor

    init(level: Float?, isChargingOrFull: Bool = false) {
        battery = FakeBattery(level: level, isChargingOrFull: isChargingOrFull)
        monitor = BatteryMonitor(battery: battery, clock: clock)
    }

    /// Starts watching and waits for the first check, which ends in the wait for the next.
    func start() async throws {
        monitor.start(isPaused: false) { [sink, monitor] in await sink.receive($0, from: monitor) }
        try await clock.waitForSleepers(1)
    }

    /// Moves on to the next check and waits for it to finish.
    func tick() async throws {
        clock.advance(by: BatteryMonitor.checkInterval)
        try await clock.waitForSleepers(1)
    }
}

/// Yields until `condition` holds, for a check the test can't join.
private func waitUntil(_ condition: () async -> Bool) async {
    while await !condition() { await Task.yield() }
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
        #expect(await rig.sink.warnings.isEmpty)
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
        #expect(await rig.sink.warnings == [BatteryMonitor.Warning(level: .low, text: low18)])
    }

    @Test
    func warnsAgainOnDroppingBelow10Percent() async throws {
        let rig = Rig(level: 0.18)
        try await rig.start()
        rig.battery.set(level: 0.09)
        try await rig.tick()
        try await rig.tick()

        let warnings = await rig.sink.warnings
        #expect(warnings.map(\.text) == [low18, veryLow9])
        #expect(warnings.last?.level == .veryLow)
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

    // a warning the engine dropped, as during a call or while announcements are paused, would be lost
    @Test
    func warnsAgainUntilDelivered() async throws {
        let rig = Rig(level: 0.18)
        await rig.sink.setDelivers(false)
        try await rig.start()
        try await rig.tick()
        #expect(await rig.sink.texts == [low18, low18])

        await rig.sink.setDelivers(true)
        try await rig.tick()
        try await rig.tick()
        #expect(await rig.sink.texts == [low18, low18, low18])
    }

    // the threshold is on the level read, and the number said stays under it
    @Test(arguments: [
        (Float(0.189999), "Battery is low, 19 percent."),
        (Float(0.195), "Battery is low, 19 percent."),
        (Float(0.0951), "Battery is very low, 9 percent. Turning off the camera view saves power."),
    ])
    func saysTheRoundedPercentUnderTheThreshold(level: Float, text: String) async throws {
        let rig = Rig(level: level)
        try await rig.start()

        #expect(await rig.sink.texts == [text])
    }

    @Test
    func unknownLevelSaysNothing() async throws {
        let rig = Rig(level: nil)
        try await rig.start()
        try await rig.tick()

        #expect(rig.battery.reads == 2)
        #expect(await rig.sink.warnings.isEmpty)
    }

    @Test
    func pluggedInSaysNothingUntilUnplugged() async throws {
        let rig = Rig(level: 0.05, isChargingOrFull: true)
        try await rig.start()
        try await rig.tick()
        #expect(rig.battery.reads == 2)
        #expect(await rig.sink.warnings.isEmpty)

        rig.battery.set(level: 0.09)
        try await rig.tick()
        #expect(await rig.sink.texts == [veryLow9])
    }

    @Test
    func pausedSkipsChecksAndResumingChecksAtOnce() async throws {
        let rig = Rig(level: 0.25)
        try await rig.start()
        rig.monitor.setPaused(true)
        rig.battery.set(level: 0.09)
        try await rig.tick()
        #expect(rig.battery.reads == 1)
        #expect(await rig.sink.warnings.isEmpty)

        rig.monitor.setPaused(false)
        await waitUntil { await rig.sink.texts == [veryLow9] }
        #expect(rig.battery.reads == 2)
    }

    @Test
    func startingPausedSkipsTheFirstCheck() async throws {
        let rig = Rig(level: 0.09)
        rig.monitor.start(isPaused: true) { [sink = rig.sink, monitor = rig.monitor] in
            await sink.receive($0, from: monitor)
        }
        try await rig.clock.waitForSleepers(1)

        #expect(rig.battery.reads == 0)
    }

    @Test
    func stopEndsChecksAndTheReading() async throws {
        let rig = Rig(level: 0.25)
        try await rig.start()
        rig.monitor.stop()
        // the next check's wait is cancelled, so no advance can wake it
        #expect(rig.clock.sleeperCount == 0)
        rig.battery.set(level: 0.09)
        rig.clock.advance(by: BatteryMonitor.checkInterval)

        #expect(rig.battery.reads == 1)
        #expect(await rig.sink.warnings.isEmpty)
        await waitUntil { rig.battery.stops == 1 }
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
