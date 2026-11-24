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
    private func analyzer(_ meshSwitch: RestartingMeshSwitch, perception: ScenePerception) -> ARSceneAnalyzer {
        ARSceneAnalyzer(
            sessionManager: ARSessionManager(),
            perception: perception,
            performance: PerformanceModeMonitor(),
            announcements: PlaceholderAnnouncementEngine(),
            setMeshReconstruction: { meshSwitch.set($0) }
        )
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
    func quickMeshChangesCollapseIntoTheLatest() async {
        let meshSwitch = RestartingMeshSwitch()
        let analyzer = analyzer(meshSwitch, perception: ScenePerception())

        analyzer.navigate(to: "the door")
        analyzer.navigate(to: nil)
        analyzer.navigate(to: "the stairs")
        for await enabled in meshSwitch.switches {
            #expect(enabled)
            break
        }
        try? await Task.sleep(for: .milliseconds(600))
        meshSwitch.finish()

        var later: [Bool] = []
        for await enabled in meshSwitch.switches { later.append(enabled) }
        #expect(later.isEmpty)
    }
}
