import Foundation
import Testing
@testable import AccessAble

@MainActor
struct PresenceWriteQueueTests {
    @Test func offlineCannotOvertakeAnInFlightOnlineWrite() async throws {
        let queue = PresenceWriteQueue()
        let gate = PresenceTestGate()
        var writes: [String] = []
        let online = Task {
            try await queue.run { writes.append("online started"); await gate.pause(); writes.append("online saved") }
        }
        await gate.waitForPause()
        let offline = Task { try await queue.run { writes.append("offline saved") } }
        gate.resume()
        try await online.value
        try await offline.value
        #expect(writes == ["online started", "online saved", "offline saved"])
    }

    @Test func failedOnlineWriteDoesNotPreventOfflineCleanup() async throws {
        let queue = PresenceWriteQueue()
        do { try await queue.run { throw CallSafetyError.unavailable } }
        catch {}
        var cleanedUp = false
        try await queue.run { cleanedUp = true }
        #expect(cleanedUp)
    }
}

@MainActor
private final class PresenceTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation = $0; waiting?.resume(); waiting = nil }
    }
    func waitForPause() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
