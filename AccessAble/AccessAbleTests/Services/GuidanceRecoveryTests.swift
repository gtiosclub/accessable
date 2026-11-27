import Foundation
import Testing
@testable import AccessAble

struct GuidanceRecoveryTests {
    @Test(.timeLimit(.minutes(1)))
    func aStopIsAnnouncedAndRestartedOnce() async throws {
        let guidance = FakeGuidance()
        let sink = RecordingSink()
        let recovery = GuidanceRecovery()
        recovery.hold(guidance, announcements: sink)
        try await guidance.waitForSubscribers(1)

        guidance.send(.stopped(reason: "Tracking could not be recovered."))
        // failing again before it ever ran is not retried
        guidance.send(.interrupted)
        guidance.send(.stopped(reason: "Tracking could not be recovered."))
        guidance.send(.running)
        await sink.waitFor("guidance-restored")

        #expect(guidance.restartCount == 1)
        #expect(sink.keys == ["guidance-stopped", "guidance-stopped", "guidance-restored"])
        recovery.release()
    }

    @Test(.timeLimit(.minutes(1)))
    func runningAgainAllowsTheNextRestart() async throws {
        let guidance = FakeGuidance()
        let sink = RecordingSink()
        let recovery = GuidanceRecovery()
        recovery.hold(guidance, announcements: sink)
        try await guidance.waitForSubscribers(1)

        guidance.send(.stopped(reason: "first"))
        guidance.send(.running)
        guidance.send(.stopped(reason: "second"))
        guidance.send(.running)
        await sink.waitFor("guidance-restored")
        await sink.waitFor("guidance-restored")

        #expect(guidance.restartCount == 2)
        recovery.release()
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedRestartIsAnnounced() async throws {
        let guidance = FakeGuidance(restartFails: true)
        let sink = RecordingSink()
        let recovery = GuidanceRecovery()
        recovery.hold(guidance, announcements: sink)
        try await guidance.waitForSubscribers(1)

        guidance.send(.stopped(reason: "Tracking could not be recovered."))
        await sink.waitFor("guidance-restart-failed")

        #expect(sink.keys == ["guidance-stopped", "guidance-restart-failed"])
        recovery.release()
    }

    // a stop already there when the watch starts isn't news
    @Test(.timeLimit(.minutes(1)))
    func theStatusAtTheStartIsNotAChange() async throws {
        let guidance = FakeGuidance()
        guidance.send(.stopped(reason: "earlier"))
        let sink = RecordingSink()
        let recovery = GuidanceRecovery()
        recovery.hold(guidance, announcements: sink)
        try await guidance.waitForSubscribers(1)

        guidance.send(.running)
        await sink.waitFor("guidance-restored")

        #expect(guidance.restartCount == 0)
        #expect(sink.keys == ["guidance-restored"])
        recovery.release()
    }

    @Test(.timeLimit(.minutes(1)))
    func holdersShareOneWatchUntilTheLastLetsGo() async throws {
        let guidance = FakeGuidance()
        let sink = RecordingSink()
        let recovery = GuidanceRecovery()
        recovery.hold(guidance, announcements: sink)
        recovery.hold(guidance, announcements: sink)
        try await guidance.waitForSubscribers(1)

        recovery.release()
        guidance.send(.stopped(reason: "Tracking could not be recovered."))
        for await _ in guidance.restarts { break }
        #expect(guidance.restartCount == 1)
        #expect(sink.keys == ["guidance-stopped"])

        recovery.release()
        try await guidance.waitForSubscribers(0)
    }

    @Test(.timeLimit(.minutes(1)))
    func afterTheLastReleaseAStopDoesNothing() async throws {
        let guidance = FakeGuidance()
        let sink = RecordingSink()
        let recovery = GuidanceRecovery()
        recovery.hold(guidance, announcements: sink)
        try await guidance.waitForSubscribers(1)

        recovery.release()
        try await guidance.waitForSubscribers(0)
        guidance.send(.stopped(reason: "Tracking could not be recovered."))

        #expect(guidance.restartCount == 0)
        #expect(sink.keys.isEmpty)
    }

    @Test
    func anExtraReleaseIsIgnored() async throws {
        let guidance = FakeGuidance()
        let recovery = GuidanceRecovery()
        recovery.release()
        recovery.hold(guidance, announcements: RecordingSink())
        try await guidance.waitForSubscribers(1)

        recovery.release()
        try await guidance.waitForSubscribers(0)
    }
}

/// The camera screen's side: it keeps the screen awake itself and leaves restarts to the shared recovery.
@MainActor
struct GuidanceStatusMonitorTests {
    @Test(.timeLimit(.minutes(1)))
    func theCameraScreenAloneStillRestartsOnce() async throws {
        let guidance = FakeGuidance()
        let sink = RecordingSink()
        let monitor = GuidanceStatusMonitor(recovery: GuidanceRecovery(), announcements: sink)
        monitor.watch(guidance)
        // the monitor's own subscription and the recovery's
        try await guidance.waitForSubscribers(2)

        guidance.send(.stopped(reason: "Tracking could not be recovered."))
        guidance.send(.running)
        await sink.waitFor("guidance-restored")

        #expect(guidance.restartCount == 1)
        #expect(sink.keys == ["guidance-stopped", "guidance-restored"])
        monitor.stop()
        try await guidance.waitForSubscribers(0)
    }

    // watching again replaces the subscription without taking a second hold
    @Test(.timeLimit(.minutes(1)))
    func watchingAgainKeepsOneHold() async throws {
        let guidance = FakeGuidance()
        let sink = RecordingSink()
        let recovery = GuidanceRecovery()
        // the trip's hold, so the recovery is watching throughout
        recovery.hold(guidance, announcements: sink)
        try await guidance.waitForSubscribers(1)
        let monitor = GuidanceStatusMonitor(recovery: recovery, announcements: sink)
        monitor.watch(guidance)
        monitor.watch(guidance)

        monitor.stop()
        recovery.release()
        try await guidance.waitForSubscribers(0)
    }
}
