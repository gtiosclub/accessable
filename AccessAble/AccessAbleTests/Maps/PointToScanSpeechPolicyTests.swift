import Foundation
import Synchronization
import Testing
@testable import AccessAble

@MainActor
struct PointToScanSpeechPolicyTests {
    @Test
    func holdsBeforeAnnouncing() async throws {
        let clock = ManualClock()
        let policy = PointToScanSpeechPolicy(clock: clock)
        var announced: [String] = []
        policy.schedule(placeID: "a") { announced.append($0) }
        try await clock.waitForSleepers(1)
        #expect(announced.isEmpty)
        clock.advance(by: .milliseconds(300))
        try await Task.yield()
        #expect(announced == ["a"])
    }

    @Test
    func doesNotRepeatWithinCooldownUnlessTurnedAway() async throws {
        let clock = ManualClock()
        let dates = Mutex([Date(timeIntervalSinceReferenceDate: 0)])
        let policy = PointToScanSpeechPolicy(clock: clock) { dates.withLock { $0[0] } }
        var announced: [String] = []
        policy.schedule(placeID: "a") { announced.append($0) }
        try await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(300))
        try await Task.yield()
        policy.schedule(placeID: "a") { announced.append($0) }
        try await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(300))
        try await Task.yield()
        #expect(announced == ["a"])
        policy.userTurnedAway()
        dates.withLock { $0[0] = $0[0].addingTimeInterval(11) }
        policy.schedule(placeID: "a") { announced.append($0) }
        try await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(300))
        try await Task.yield()
        #expect(announced == ["a", "a"])
    }
}