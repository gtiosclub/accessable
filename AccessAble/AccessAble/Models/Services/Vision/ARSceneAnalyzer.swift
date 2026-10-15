import ARKit
import Foundation
import Synchronization
import UIKit

/// Owner: Computer Vision (1.4). The live `SceneObservationProviding` service: subscribes to
/// the shared `ARSessionManager`, runs `ScenePerception` on its frames, publishes one
/// `SceneObservation` per analyzed frame and submits obstacle announcements to the shared
/// `AnnouncementSink`.
///
/// Frames go through a `LatestOnlyProcessor` (T3), so when analysis is slower than the
/// camera, stale frames are dropped rather than queued. `PerformanceMode` thins the input
/// further by only offering every Nth camera frame.
final class ARSceneAnalyzer: SceneObservationProviding, Sendable {
    let sessionManager: ARSessionManager
    let perception: ScenePerception

    private let performance: any PerformanceModeProviding
    private let broadcaster = Broadcaster<SceneObservation>(replaysLatest: true)
    private let processor: LatestOnlyProcessor<CapturedFrame>
    /// Announcements go through a stream drained by one task, so they reach the sink in
    /// order without the analysis queue ever waiting on it.
    private let announcementQueue: AsyncStream<AnnouncementEvent>.Continuation

    private struct State {
        var frameCounter = 0
        var frameStride = PerformanceMode.normal.detectionFrameStride
        var interfaceOrientation: UIInterfaceOrientation = .portrait
        var subscription: ARSessionManager.Subscription?
        var modeTask: Task<Void, Never>?
    }

    private let state = Mutex(State())

    init(
        sessionManager: ARSessionManager,
        perception: ScenePerception = ScenePerception(),
        performance: any PerformanceModeProviding,
        announcements: any AnnouncementSink
    ) {
        self.sessionManager = sessionManager
        self.perception = perception
        self.performance = performance

        let (pending, announcementQueue) = AsyncStream.makeStream(
            of: AnnouncementEvent.self, bufferingPolicy: .bufferingNewest(16)
        )
        self.announcementQueue = announcementQueue
        // Ends when the analyzer, and with it the continuation, goes away.
        Task {
            for await event in pending {
                await announcements.submit(event)
            }
        }

        processor = LatestOnlyProcessor(label: "AccessAble.ARSceneAnalyzer.analysis") {
            [perception, broadcaster, announcementQueue] captured in
            let analysis = perception.analyze(captured.frame, interfaceOrientation: captured.interfaceOrientation)
            broadcaster.send(analysis.observation)
            for event in analysis.announcements {
                announcementQueue.yield(event)
            }
        }
    }

    // MARK: - SceneObservationProviding

    func observations() -> AsyncStream<SceneObservation> {
        broadcaster.stream()
    }

    func start() async throws {
        try await MainActor.run { try sessionManager.start() }

        let subscription = sessionManager.addFrameHandler { [weak self] frame in
            self?.receive(frame)
        }
        // Adapt the frame stride to the global performance mode (owned by 3.3).
        let modeTask = Task { [weak self, performance] in
            for await mode in performance.modes() {
                self?.state.withLock { $0.frameStride = max(1, mode.detectionFrameStride) }
            }
        }
        let previous = state.withLock { state in
            defer {
                state.subscription = subscription
                state.modeTask = modeTask
            }
            return (state.subscription, state.modeTask)
        }
        if let subscription = previous.0 { sessionManager.removeFrameHandler(subscription) }
        previous.1?.cancel()
    }

    func stop() async {
        let (subscription, modeTask) = state.withLock { state in
            defer {
                state.subscription = nil
                state.modeTask = nil
            }
            return (state.subscription, state.modeTask)
        }
        if let subscription { sessionManager.removeFrameHandler(subscription) }
        modeTask?.cancel()
        processor.cancelPending()
        await MainActor.run { sessionManager.stop() }
    }

    /// Tells the analyzer how the device is held, so Vision gets the right image
    /// orientation and boxes come back upright.
    func setInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        state.withLock { $0.interfaceOrientation = orientation }
    }

    // MARK: - Frames

    private func receive(_ frame: ARFrame) {
        let orientation = state.withLock { state -> UIInterfaceOrientation? in
            state.frameCounter += 1
            return state.frameCounter % state.frameStride == 0 ? state.interfaceOrientation : nil
        }
        guard let orientation else { return }
        processor.submit(CapturedFrame(frame: frame, interfaceOrientation: orientation))
    }
}

/// Carries an `ARFrame` from the session's queue to the analysis queue.
///
/// `@unchecked Sendable` because `ARFrame` is not `Sendable`. It is safe because ARKit never
/// mutates a delivered frame and, once submitted, the frame is only read on the analysis queue.
private struct CapturedFrame: @unchecked Sendable {
    let frame: ARFrame
    let interfaceOrientation: UIInterfaceOrientation
}
