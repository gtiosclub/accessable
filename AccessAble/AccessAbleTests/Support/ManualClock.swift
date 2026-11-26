import Foundation
import Synchronization

/// A clock the test moves by hand. A sleep returns once `advance(by:)` reaches its deadline,
/// so timers fire exactly when the test says and no test waits in real time.
///
/// Advancing only wakes sleeps that have started, so first await `waitForSleepers(_:)` for
/// the timers the advance is meant to fire. One advance wakes each sleep at most once: a
/// repeating timer sleeps again only after it runs, so it needs one advance per tick.
final class ManualClock: Clock {
    struct Instant: InstantProtocol {
        let offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [UUID: Sleeper] = [:]
        var waiters: [UUID: Waiter] = [:]
        /// Sleeps and waits cancelled before they started waiting.
        var cancelled: Set<UUID> = []

        /// Removes and returns the waiters that enough sleepers have now started for.
        mutating func takeSatisfiedWaiters() -> [Waiter] {
            let count = sleepers.count
            let satisfied = waiters.filter { $0.value.count <= count }
            for id in satisfied.keys { waiters.removeValue(forKey: id) }
            return Array(satisfied.values)
        }
    }

    private let state = Mutex(State())

    var now: Instant {
        state.withLock { $0.now }
    }

    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = UUID()
        // After the cancellation handler is gone, so it can't record this sleep again.
        defer { state.withLock { _ = $0.cancelled.remove(id) } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Start { case cancelled, due, waiting([Waiter]) }
                let start = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return Start.cancelled }
                    if deadline <= state.now { return .due }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .waiting(state.takeSatisfiedWaiters())
                }
                switch start {
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .due: continuation.resume()
                case .waiting(let satisfied): for waiter in satisfied { waiter.continuation.resume() }
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state in
                guard let sleeper = state.sleepers.removeValue(forKey: id) else {
                    state.cancelled.insert(id)
                    return Sleeper?.none
                }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time on and wakes every sleep whose deadline it reaches. The woken sleeps run in
    /// whatever order the scheduler picks, not by deadline.
    func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }
            for id in due.keys { state.sleepers.removeValue(forKey: id) }
            return Array(due.values)
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// Returns once at least `count` sleeps are waiting on the clock.
    /// - Throws: `CancellationError` if the task is cancelled first, so a timer that never
    ///   starts fails at the test's time limit instead of hanging the run.
    func waitForSleepers(_ count: Int) async throws {
        let id = UUID()
        // After the cancellation handler is gone, so it can't record this wait again.
        defer { state.withLock { _ = $0.cancelled.remove(id) } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Start { case cancelled, satisfied, waiting }
                let start = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return Start.cancelled }
                    if state.sleepers.count >= count { return .satisfied }
                    state.waiters[id] = Waiter(count: count, continuation: continuation)
                    return .waiting
                }
                switch start {
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .satisfied: continuation.resume()
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
}
