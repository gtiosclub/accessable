import Dispatch
import Synchronization

/// Runs `process` on a private serial queue, always on the newest value submitted.
/// Owner: Computer Vision (1.4 / task T3).
///
/// When values arrive faster than they can be processed, the ones in between are dropped
/// rather than queued: for guidance, the current frame is worth more than a backlog of old
/// ones. At most two values are alive at once — the one being processed and the newest
/// pending one — which also keeps ARKit's small frame-buffer pool from running dry.
///
/// ```
/// submit(1) → processing 1
/// submit(2) → pending 2
/// submit(3) → pending 3 (2 is dropped)
/// 1 finishes → processing 3
/// ```
final class LatestOnlyProcessor<Input: Sendable>: Sendable {
    private struct State {
        var pending: Input?
        var isProcessing = false
    }

    private let state = Mutex(State())
    private let queue: DispatchQueue
    private let process: @Sendable (Input) -> Void

    init(label: String, qos: DispatchQoS = .userInitiated, process: @escaping @Sendable (Input) -> Void) {
        queue = DispatchQueue(label: label, qos: qos)
        self.process = process
    }

    /// Hands `input` over for processing. Cheap and safe to call from any thread.
    func submit(_ input: Input) {
        let shouldStart = state.withLock { state in
            state.pending = input
            guard !state.isProcessing else { return false }
            state.isProcessing = true
            return true
        }
        if shouldStart {
            queue.async { self.drain() }
        }
    }

    /// Drops the pending value, if any. A value already being processed still finishes.
    func cancelPending() {
        state.withLock { $0.pending = nil }
    }

    private func drain() {
        while let input = takePending() {
            process(input)
        }
    }

    /// Clears `isProcessing` in the same critical section that finds nothing pending, so a
    /// value submitted at that moment either is picked up here or starts a new drain.
    private func takePending() -> Input? {
        state.withLock { state in
            let input = state.pending
            state.pending = nil
            if input == nil { state.isProcessing = false }
            return input
        }
    }
}
