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
final class ARSceneAnalyzer: SceneObservationProviding, SceneDescribing, AskedImageProviding, SceneNavigating, Sendable {
    let sessionManager: ARSessionManager
    let perception: ScenePerception
    /// Idle unless a field test is being recorded from the Live detection screen.
    let recorder = FieldTestRecorder()

    private let performance: any PerformanceModeProviding
    private let askAI: AskAI
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
        /// The still the latest Ask AI question was answered from.
        var lastAskedImage: Data?
    }

    private let state = Mutex(State())

    init(
        sessionManager: ARSessionManager,
        perception: ScenePerception = ScenePerception(),
        performance: any PerformanceModeProviding,
        announcements: any AnnouncementSink,
        askAI: AskAI = AskAI()
    ) {
        self.sessionManager = sessionManager
        self.perception = perception
        self.performance = performance
        self.askAI = askAI

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
            [perception, broadcaster, announcementQueue, recorder, sessionManager] captured in
            let analysis = perception.analyze(captured.frame, interfaceOrientation: captured.interfaceOrientation)
            broadcaster.send(analysis.observation)
            // Register emitted event IDs before delivery starts. A delivered warning can arrive
            // after its field-test scenario closes, and the recorder must retain its origin.
            recorder.record(FieldTestRecorder.FrameRecord(
                analysis: analysis,
                diagnostics: perception.diagnostics,
                frameTimestamp: captured.frame.timestamp,
                now: ProcessInfo.processInfo.systemUptime,
                tracking: sessionManager.trackingStateDescription,
                cameraFPS: sessionManager.healthReport.averageFPS
            ))
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
        // Tracking restarts from scratch, so nothing remembered about the old world holds.
        perception.reset()

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

    // MARK: - SceneDescribing

    /// Tier A: built from the latest observation, instantly and offline (T18).
    func describeCurrentScene() async -> String {
        SceneDescriptionBuilder().describe(broadcaster.latest ?? .empty)
    }

    /// Tier B, "Ask AI" (T19): the next camera frame as a still, plus what the pipeline
    /// last saw (the objects, distances and directions "Describe my surroundings" uses),
    /// answered on the device. Runs beside the obstacle pipeline, never in it.
    /// `locationContext` is not used yet.
    func ask(_ question: String, locationContext: String?) async throws -> String {
        state.withLock { $0.lastAskedImage = nil }
        let imageData = try await captureStillImage()
        state.withLock { $0.lastAskedImage = imageData }
        return try await askAI.answer(question, imageData: imageData, observation: broadcaster.latest ?? .empty).answer
    }

    /// The next frame from the shared session as an upright JPEG. Frames only flow while
    /// the session runs, so this gives up after `timeout` rather than waiting forever.
    @concurrent
    private func captureStillImage(timeout: Duration = .seconds(1)) async throws -> Data {
        let orientation = CGImagePropertyOrientation(cameraImageIn: state.withLock { $0.interfaceOrientation })
        let (frames, continuation) = AsyncStream.makeStream(of: CapturedImage.self, bufferingPolicy: .bufferingNewest(1))
        // Only hands the buffer on; the JPEG is encoded here, off the frame queue.
        let subscription = sessionManager.addFrameHandler { frame in
            continuation.yield(CapturedImage(pixelBuffer: frame.capturedImage))
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            continuation.finish()
        }
        defer {
            sessionManager.removeFrameHandler(subscription)
            continuation.finish()
            timeoutTask.cancel()
        }

        for await image in frames {
            return try stillImageJPEG(from: image.pixelBuffer, orientation: orientation)
        }
        throw AskAIError.noCameraImage
    }

    // MARK: - AskedImageProviding

    var lastAskedImage: Data? { state.withLock { $0.lastAskedImage } }

    // MARK: - SceneNavigating

    func navigate(to query: String?) {
        perception.navigate(to: query)
    }

    var navigationStatus: NavigationStatus? { perception.navigationStatus }

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

/// Carries one camera image from the session's queue to an Ask AI question.
///
/// `@unchecked Sendable` because `CVPixelBuffer` is not `Sendable`. It is safe because ARKit
/// never writes to a delivered image and Ask AI only reads it, once, to encode the still.
private struct CapturedImage: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
}

/// Lets the UI show which camera image an Ask AI answer came from. Separate from
/// `SceneDescribing` so that contract stays as it is; services without a camera don't conform.
protocol AskedImageProviding: Sendable {
    /// The JPEG of the latest question's still; nil before any question, or if capture failed.
    var lastAskedImage: Data? { get }
}

/// "Take me to the chair": scan the room by turning on the spot, then be steered to it.
/// Separate from `SceneObservationProviding` so that contract stays as it is.
protocol SceneNavigating: Sendable {
    /// Starts a request, replacing any current one; nil cancels.
    func navigate(to query: String?)
    /// Progress of the current request, refreshed with every analyzed frame.
    var navigationStatus: NavigationStatus? { get }
}
