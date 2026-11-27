import Foundation
import Testing
@testable import AccessAble

/// How long `ARSessionManager` waits for ARKit to relocalize after an interruption.
struct RelocalizationTimeoutTests {
    @Test(.timeLimit(.minutes(1)))
    func guidanceStopsWhenTrackingDoesNotComeBackInTime() async throws {
        let clock = ManualClock()
        let manager = ARSessionManager(clock: clock)
        let statuses = manager.guidanceStatuses()
        manager.sessionWasInterrupted(manager.session)
        manager.sessionInterruptionEnded(manager.session)
        try await clock.waitForSleepers(1)

        clock.advance(by: ARSessionManager.relocalizationTimeout - .milliseconds(1))
        #expect(manager.guidanceStatus == .recovering)
        #expect(clock.sleeperCount == 1)

        clock.advance(by: .milliseconds(1))
        for await status in statuses {
            guard case .stopped = status else { continue }
            #expect(status == .stopped(reason: "Tracking could not be recovered."))
            break
        }
        #expect(ARSessionManager.relocalizationTimeout == .seconds(5))
    }

    @Test(.timeLimit(.minutes(1)))
    func trackingComingBackFirstCancelsTheTimeout() async throws {
        let clock = ManualClock()
        let manager = ARSessionManager(clock: clock)
        manager.sessionWasInterrupted(manager.session)
        manager.sessionInterruptionEnded(manager.session)
        try await clock.waitForSleepers(1)

        manager.trackingBecameNormal()
        #expect(clock.sleeperCount == 0)
        clock.advance(by: ARSessionManager.relocalizationTimeout)

        #expect(manager.guidanceStatus == .running)
    }
}
