import ARKit
import Foundation

/// Keeps CV processing pinned to the newest `ARFrame`. If a frame arrives while one is still
/// being processed, it replaces whatever was pending instead of queuing — so processing never
/// falls behind ARKit's capture rate by working through a backlog of stale frames.
///
/// Feed frames from `ARSessionDelegate.session(_:didUpdate:)` via `enqueue(_:)`. `process` is
/// called with each frame actually processed; intermediate frames never reach it. No real
/// `ARSession` is required to use or test this — any `ARFrame`, including ones from a mock
/// frame producer, works.
///
/// `ARFrame` isn't `Sendable`, so this type guards its own state with a lock rather than an
/// actor and declares itself `@unchecked Sendable` — the lock is what makes that safe.
final class LatestFrameProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingFrame: ARFrame?
    private var processingFlag = false

    private let process: (ARFrame) async -> Void

    init(process: @escaping (ARFrame) async -> Void) {
        self.process = process
    }

    /// The newest frame waiting to be processed, if any. Read-only; mainly for tests.
    var latestFrame: ARFrame? { withLock { pendingFrame } }

    /// Whether a frame is currently being processed.
    var isProcessing: Bool { withLock { processingFlag } }

    /// Call this with every frame ARKit delivers. Cheap and safe to call from any thread.
    func enqueue(_ frame: ARFrame) {
        let needsToStart = withLock {
            pendingFrame = frame
            let shouldStart = !processingFlag
            if shouldStart { processingFlag = true }
            return shouldStart
        }

        if needsToStart {
            Task { await drain() }
        }
    }

    /// Repeatedly pulls and processes the newest pending frame until none remain.
    private func drain() async {
        while true {
            guard let frame = takeNextFrameOrStop() else { return }
            await process(frame)
        }
    }

    /// Clearing `pendingFrame` and (when nothing is left) `processingFlag` happens under the
    /// same lock acquisition so a frame that arrives mid-drain is never lost or left stranded.
    private func takeNextFrameOrStop() -> ARFrame? {
        withLock {
            let frame = pendingFrame
            pendingFrame = nil
            if frame == nil { processingFlag = false }
            return frame
        }
    }

    // FLAG (bug caught at build time): `drain()` originally called `lock.lock()`/`lock.unlock()`
    // directly in its `async` body. That fails to compile on this SDK — "instance method 'lock'
    // is unavailable from asynchronous contexts; Use async-safe scoped locking instead" — because
    // NSLock's lock/unlock aren't safe to straddle a suspension point. Every critical section is
    // now routed through this synchronous helper so no `lock()`/`unlock()` call is ever made
    // directly from `async` code.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
