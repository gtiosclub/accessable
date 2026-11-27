import Foundation
import Testing
@testable import AccessAble

/// A mesh switch that reports tracking restarted, as leaving geo-tracking for the mesh does.
private final class RestartingMeshSwitch: Sendable {
    /// One element per switch, so a test can wait for it without a clock.
    let switches: AsyncStream<Bool>
    private let switched: AsyncStream<Bool>.Continuation

    init() {
        (switches, switched) = AsyncStream.makeStream()
    }

    func finish() { switched.finish() }

    @MainActor
    func set(_ enabled: Bool) -> Bool {
        switched.yield(enabled)
        return enabled
    }
}

@MainActor
struct SceneNavigationRestartTests {
    private func analyzer(
        _ meshSwitch: RestartingMeshSwitch,
        perception: ScenePerception,
        clock: any Clock<Duration> = ContinuousClock()
    ) -> ARSceneAnalyzer {
        ARSceneAnalyzer(
            sessionManager: ARSessionManager(),
            perception: perception,
            performance: PerformanceModeMonitor(),
            announcements: PlaceholderAnnouncementEngine(),
            setMeshReconstruction: { meshSwitch.set($0) },
            startSession: {},
            clock: clock
        )
    }

    /// The switches made until now, ending the stream.
    private func remainingSwitches(_ meshSwitch: RestartingMeshSwitch) async -> [Bool] {
        meshSwitch.finish()
        var switches: [Bool] = []
        for await enabled in meshSwitch.switches { switches.append(enabled) }
        return switches
    }

    @Test(.timeLimit(.minutes(1)))
    func takeMeToSurvivesLeavingGeoTrackingForTheMesh() async {
        let meshSwitch = RestartingMeshSwitch()
        let perception = ScenePerception()
        let analyzer = analyzer(meshSwitch, perception: perception)

        analyzer.navigate(to: "the door")
        // The reset and the request put back run on the main actor in one go with the switch.
        for await enabled in meshSwitch.switches {
            #expect(enabled)
            break
        }

        #expect(perception.navigationQuery == "the door")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingDuringTheRestartStaysCancelled() async {
        let meshSwitch = RestartingMeshSwitch()
        let perception = ScenePerception()
        let analyzer = analyzer(meshSwitch, perception: perception)

        analyzer.navigate(to: "the door")
        var switches: [Bool] = []
        for await enabled in meshSwitch.switches {
            switches.append(enabled)
            // cancel once the restart for the mesh has happened; sooner, the debounce drops the switch on
            if switches.count == 1 { analyzer.navigate(to: nil) }
            if switches.count == 2 { break }
        }

        #expect(switches == [true, false])
        #expect(perception.navigationQuery == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingRightAwaySwitchesOnlyOff() async {
        let meshSwitch = RestartingMeshSwitch()
        let perception = ScenePerception()
        let analyzer = analyzer(meshSwitch, perception: perception)

        analyzer.navigate(to: "the door")
        analyzer.navigate(to: nil)
        // Mesh changes are debounced, so only the latest one reaches the session.
        for await enabled in meshSwitch.switches {
            #expect(!enabled)
            break
        }

        #expect(perception.navigationQuery == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func takeMeToSurvivesRestartingGuidance() async throws {
        let perception = ScenePerception()
        let analyzer = ARSceneAnalyzer(
            sessionManager: ARSessionManager(),
            perception: perception,
            performance: PerformanceModeMonitor(),
            announcements: PlaceholderAnnouncementEngine(),
            setMeshReconstruction: { _ in false },
            startSession: {}
        )
        try await analyzer.start()
        analyzer.navigate(to: "the door")

        try await analyzer.restartGuidance()

        #expect(perception.navigationQuery == "the door")
        await analyzer.stop()
    }

    // quick changes re-run the session once, for the latest
    @Test(.timeLimit(.minutes(1)))
    func quickMeshChangesCollapseIntoTheLatest() async throws {
        let meshSwitch = RestartingMeshSwitch()
        let clock = ManualClock()
        let analyzer = analyzer(meshSwitch, perception: ScenePerception(), clock: clock)

        analyzer.navigate(to: "the door")
        analyzer.navigate(to: nil)
        analyzer.navigate(to: "the stairs")
        // the earlier two were cancelled before they could wait
        try await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(300))
        for await enabled in meshSwitch.switches {
            #expect(enabled)
            break
        }

        #expect(await remainingSwitches(meshSwitch).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aChangeCancelledWithinTheDelayMakesNoSwitch() async throws {
        let meshSwitch = RestartingMeshSwitch()
        let clock = ManualClock()
        let analyzer = analyzer(meshSwitch, perception: ScenePerception(), clock: clock)

        analyzer.navigate(to: "the door")
        try await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(299))
        analyzer.navigate(to: nil)
        // the door's sleep is gone, so this one is the cancel's
        try await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(300))
        for await enabled in meshSwitch.switches {
            #expect(!enabled)
            break
        }

        #expect(await remainingSwitches(meshSwitch).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func stoppingWhileASwitchIsPendingLeavesItToTheNextStart() async throws {
        let meshSwitch = RestartingMeshSwitch()
        let clock = ManualClock()
        let perception = ScenePerception()
        let analyzer = analyzer(meshSwitch, perception: perception, clock: clock)
        try await analyzer.start()

        analyzer.setMode(.find)
        try await clock.waitForSleepers(1)
        await analyzer.stop()
        clock.advance(by: .milliseconds(300))
        try await analyzer.start()

        // the start's switches only: off for Walk, then on for the Find still wanted
        #expect(await remainingSwitches(meshSwitch) == [false, true])
        #expect(perception.mode == .find)
        await analyzer.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func takeMeToSurvivesACall() async throws {
        let perception = ScenePerception()
        let analyzer = ARSceneAnalyzer(
            sessionManager: ARSessionManager(),
            perception: perception,
            performance: PerformanceModeMonitor(),
            announcements: PlaceholderAnnouncementEngine(),
            setMeshReconstruction: { _ in false },
            startSession: {}
        )
        try await analyzer.start()
        analyzer.navigate(to: "the door")

        let token = try analyzer.pauseForCall()
        try analyzer.resumeAfterCall(token)

        #expect(perception.navigationQuery == "the door")
        await analyzer.stop()
    }
}
