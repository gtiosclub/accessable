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
        analyzer.navigate(to: nil)
        var switches = 0
        for await _ in meshSwitch.switches {
            switches += 1
            if switches == 2 { break }
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
}
