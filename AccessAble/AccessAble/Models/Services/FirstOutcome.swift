import Synchronization

/// Resumes one continuation with whichever outcome arrives first, such as a result or a timeout.
/// Later outcomes are dropped, so the continuation is never resumed twice, and the tasks racing
/// for it are cancelled once one wins.
final class FirstOutcome<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, any Error>?
        var outcome: Result<Value, any Error>?
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Hands over the continuation to resume, at once if an outcome already came.
    func wait(_ continuation: CheckedContinuation<Value, any Error>) {
        let outcome = state.withLock { state in
            if state.outcome == nil { state.continuation = continuation }
            return state.outcome
        }
        if let outcome { continuation.resume(with: outcome) }
    }

    /// Cancels `task` once an outcome comes, or now if one already has.
    func cancelsOnFinish(_ task: Task<Void, Never>) {
        let finished = state.withLock { state in
            if state.outcome == nil { state.tasks.append(task) }
            return state.outcome != nil
        }
        if finished { task.cancel() }
    }

    /// Returns whether this outcome came first.
    @discardableResult
    func finish(_ outcome: Result<Value, any Error>) -> Bool {
        let pending = state.withLock { state -> (CheckedContinuation<Value, any Error>?, [Task<Void, Never>])? in
            guard state.outcome == nil else { return nil }
            state.outcome = outcome
            defer {
                state.continuation = nil
                state.tasks = []
            }
            return (state.continuation, state.tasks)
        }
        guard let (continuation, tasks) = pending else { return false }
        for task in tasks { task.cancel() }
        continuation?.resume(with: outcome)
        return true
    }
}
