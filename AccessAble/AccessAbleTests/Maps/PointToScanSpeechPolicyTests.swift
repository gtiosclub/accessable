import Foundation
import Testing
@testable import AccessAble

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PointToScanSpeechPolicyTests {
    private let clock = ManualClock()
    private let date = ManualDate()
    private let policy: PointToScanSpeechPolicy
    private let spoken = SpokenPlaces()

    init() {
        policy = PointToScanSpeechPolicy(clock: clock, now: { [date] in date.now })
    }

    private func update(_ target: String?, turnedAway: Bool = false) {
        policy.update(target: target, turnedAwayFromLastSpoken: turnedAway) { [spoken] in spoken.ids.append($0) }
    }

    /// Fires the hold that is waiting and returns once it has run.
    private func finishHold() async throws {
        try await clock.waitForSleepers(1)
        clock.advance(by: PointToScanSpeechPolicy.holdDuration)
        await policy.holdTask?.value
    }

    /// Points at `target` until it is named.
    private func speak(_ target: String) async throws {
        update(target)
        try await finishHold()
    }

    @Test
    func steadyPointSpeaksOnceAfterTheHold() async throws {
        update("a")
        try await clock.waitForSleepers(1)
        for _ in 0..<2 {
            clock.advance(by: .milliseconds(100))
            update("a")
            #expect(spoken.ids.isEmpty)
        }
        clock.advance(by: .milliseconds(100))
        await policy.holdTask?.value
        #expect(spoken.ids == ["a"])
        for _ in 0..<5 {
            date.advance(by: 1)
            update("a")
        }
        #expect(spoken.ids == ["a"])
        #expect(clock.sleeperCount == 0)
    }

    @Test
    func newTargetRestartsTheHold() async throws {
        update("a")
        try await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(200))
        update("b")
        try await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(200))
        #expect(spoken.ids.isEmpty)
        clock.advance(by: .milliseconds(100))
        await policy.holdTask?.value
        #expect(spoken.ids == ["b"])
    }

    @Test
    func repeatsAStillPointedPlaceOnlyAfterTheRepeatInterval() async throws {
        try await speak("a")
        date.advance(by: PointToScanSpeechPolicy.repeatInterval - 1)
        update("a")
        #expect(spoken.ids == ["a"])
        date.advance(by: 1)
        update("a")
        #expect(spoken.ids == ["a", "a"])
    }

    @Test
    func turningAwayAndBackSpeaksAgain() async throws {
        try await speak("a")
        update(nil, turnedAway: true)
        date.advance(by: PointToScanSpeechPolicy.turnAwayDuration)
        update(nil, turnedAway: true)
        try await speak("a")
        #expect(spoken.ids == ["a", "a"])
    }

    @Test
    func briefWiggleAwayDoesNotSpeakAgain() async throws {
        try await speak("a")
        update(nil, turnedAway: true)
        date.advance(by: PointToScanSpeechPolicy.turnAwayDuration / 2)
        update(nil, turnedAway: true)
        try await speak("a")
        #expect(spoken.ids == ["a"])
    }

    @Test
    func newScanSessionSpeaksTheSamePlace() async throws {
        try await speak("a")
        policy.resetScanSession()
        try await speak("a")
        #expect(spoken.ids == ["a", "a"])
    }
}

@MainActor
private final class SpokenPlaces {
    var ids: [String] = []
}
