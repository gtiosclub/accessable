import Foundation
import Synchronization
@testable import AccessAble

/// A camera whose guidance status the test sets by hand, recording restarts and camera holds.
final class FakeGuidance: SceneObservationProviding, GuidanceStatusProviding, Sendable {
    struct RestartFailed: LocalizedError {
        var errorDescription: String? { "No camera." }
    }

    private typealias Waiter = (count: Int, continuation: CheckedContinuation<Void, any Error>)

    private struct State {
        var status = GuidanceStatus.running
        var subscribers: [UUID: AsyncStream<GuidanceStatus>.Continuation] = [:]
        var waiters: [UUID: Waiter] = [:]
        /// Waits cancelled before they started waiting.
        var cancelled: Set<UUID> = []
        var restartCount = 0
        var calls: [String] = []

        mutating func takeSatisfiedWaiters() -> [CheckedContinuation<Void, any Error>] {
            let count = subscribers.count
            let satisfied = waiters.filter { $0.value.count == count }
            for id in satisfied.keys { waiters.removeValue(forKey: id) }
            return satisfied.values.map(\.continuation)
        }
    }

    private let state = Mutex(State())
    private let restartFails: Bool
    /// One element per restart, so a test can wait for it without a clock.
    let restarts: AsyncStream<Void>
    private let restarted: AsyncStream<Void>.Continuation

    init(restartFails: Bool = false) {
        self.restartFails = restartFails
        (restarts, restarted) = AsyncStream.makeStream()
    }

    var restartCount: Int { state.withLock { $0.restartCount } }
    /// Camera starts and stops, in order.
    var calls: [String] { state.withLock { $0.calls } }

    /// Sends `status` to every subscriber, as the session does on a change.
    func send(_ status: GuidanceStatus) {
        let subscribers = state.withLock { state in
            state.status = status
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers { subscriber.yield(status) }
    }

    /// Returns once exactly `count` status subscriptions are open.
    /// - Throws: `CancellationError` if the task is cancelled first, so a subscription that never
    ///   opens or closes fails at the test's time limit instead of hanging the run.
    func waitForSubscribers(_ count: Int) async throws {
        let id = UUID()
        defer { state.withLock { _ = $0.cancelled.remove(id) } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Start { case cancelled, ready, waiting }
                let start = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return Start.cancelled }
                    if state.subscribers.count == count { return .ready }
                    state.waiters[id] = (count, continuation)
                    return .waiting
                }
                switch start {
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .ready: continuation.resume()
                case .waiting: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                guard let waiter = state.waiters.removeValue(forKey: id) else {
                    state.cancelled.insert(id)
                    return Waiter?.none
                }
                return waiter
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: - SceneObservationProviding

    func observations() -> AsyncStream<SceneObservation> { AsyncStream { $0.finish() } }
    func start() async throws { state.withLock { $0.calls.append("start") } }
    func stop() async { state.withLock { $0.calls.append("stop") } }

    // MARK: - GuidanceStatusProviding

    var guidanceStatus: GuidanceStatus { state.withLock { $0.status } }

    /// Starts with the current status, as `ARSessionManager` does.
    func guidanceStatuses() -> AsyncStream<GuidanceStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: GuidanceStatus.self)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            let satisfied = state.withLock { state in
                state.subscribers.removeValue(forKey: id)
                return state.takeSatisfiedWaiters()
            }
            for waiter in satisfied { waiter.resume() }
        }
        let satisfied = state.withLock { state in
            continuation.yield(state.status)
            state.subscribers[id] = continuation
            return state.takeSatisfiedWaiters()
        }
        for waiter in satisfied { waiter.resume() }
        return stream
    }

    func restartGuidance() async throws {
        state.withLock { $0.restartCount += 1 }
        restarted.yield()
        if restartFails { throw RestartFailed() }
    }
}

/// Keeps what was submitted, and hands each event to the test as it arrives.
final class RecordingSink: AnnouncementSink, Sendable {
    private let submitted = Mutex<[AnnouncementEvent]>([])
    let events: AsyncStream<AnnouncementEvent>
    private let continuation: AsyncStream<AnnouncementEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    var keys: [String?] { submitted.withLock { $0.map(\.dedupKey) } }

    func submit(_ event: AnnouncementEvent) async {
        submitted.withLock { $0.append(event) }
        continuation.yield(event)
    }

    /// Returns once an event with `key` has been submitted.
    func waitFor(_ key: String) async {
        for await event in events where event.dedupKey == key { return }
    }
}
