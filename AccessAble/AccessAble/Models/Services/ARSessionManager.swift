import ARKit
import CoreVideo
import Foundation
import Synchronization
import os

/// Owner: Computer Vision (1.4 / task T1). The one shared ARKit camera session.
///
/// Every CV module that needs camera frames or the device pose subscribes here instead of
/// running its own `ARSession`. iOS only gives the camera to one session at a time, so two
/// sessions would fight over it.
///
/// What it does:
/// - starts and stops a world-tracking session (`start()` / `stop()`)
/// - hands every `ARFrame` to whoever subscribed with `addFrameHandler(_:)`
/// - keeps a running `FrameHealthReport` so the T1 checks can be read off a device
///
/// What it does NOT do: depth. Turning on `.sceneDepth` / `.smoothedSceneDepth` is T2's
/// job. T2 adds it through the `configure` hook on `start(configure:)`, so the depth code
/// stays in T2's files and this one does not change.
///
/// Threading: frames arrive on `frameQueue`, one at a time, in order. Handlers run on that
/// queue too, so a slow handler delays the next frame. Anything heavier than reading a few
/// fields belongs behind T3's latest-frame-only queue.
///
/// `@unchecked Sendable` for the same reason as `ARSceneAnalyzer`: `ARSession` and
/// `ARFrame` are not `Sendable`. The invariants that make it safe are that all mutable
/// state sits behind a `Mutex`, the session is only configured from the main actor, and
/// frames are only delivered on `frameQueue`.
final class ARSessionManager: NSObject, @unchecked Sendable {
    /// Receives every frame. Runs on `frameQueue`.
    ///
    /// Do not hold on to the `ARFrame` after returning. ARKit reuses a small pool of
    /// frame buffers, and keeping old frames alive starves it ("delegate is retaining N
    /// ARFrames" in the console), which drops the frame rate. Copy out what you need.
    typealias FrameHandler = @Sendable (ARFrame) -> Void

    /// Lets a subscriber unsubscribe later.
    struct Subscription: Hashable, Sendable {
        fileprivate let id: UUID
    }

    /// Exposed so a preview view (`ARSCNView`, `ARView`) can render this exact session.
    /// Touch it only from the main actor.
    let session = ARSession()

    private let frameQueue = DispatchQueue(label: "AccessAble.ARSessionManager.frames")
    private let handlers = Mutex<[UUID: FrameHandler]>([:])
    private let health = Mutex(FrameHealthCheck())
    private let runningState = Mutex(false)
    private let trackingState = Mutex("not started")
    private let log = Logger(subsystem: "AccessAble", category: "ARSessionManager")

    // MARK: - Lifecycle

    /// Starts world tracking. Safe to call again; the session restarts from scratch.
    ///
    /// - Parameter configure: a chance to adjust the configuration before it runs. T2 uses
    ///   this to insert depth frame semantics.
    @MainActor
    func start(configure: (ARWorldTrackingConfiguration) -> Void = { _ in }) throws {
        guard ARWorldTrackingConfiguration.isSupported else {
            throw ARSessionManagerError.worldTrackingUnsupported
        }

        let configuration = ARWorldTrackingConfiguration()
        // World +Y points up (against gravity). The floor fit (T10) and the walking
        // corridor (T9) both assume this.
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []
        configure(configuration)

        health.withLock { $0.reset() }
        session.delegate = self
        session.delegateQueue = frameQueue
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        runningState.withLock { $0 = true }
        log.info("ARKit session started")
    }

    /// Pauses the session. Subscribers stay registered and resume getting frames on the
    /// next `start()`.
    @MainActor
    func stop() {
        session.pause()
        runningState.withLock { $0 = false }
        log.info("ARKit session paused")
    }

    var isRunning: Bool { runningState.withLock { $0 } }

    // MARK: - Subscribing to frames

    /// Calls `handler` with every new frame until the subscription is removed.
    @discardableResult
    func addFrameHandler(_ handler: @escaping FrameHandler) -> Subscription {
        let id = UUID()
        handlers.withLock { $0[id] = handler }
        return Subscription(id: id)
    }

    func removeFrameHandler(_ subscription: Subscription) {
        handlers.withLock { $0[subscription.id] = nil }
    }

    // MARK: - T1 checks

    /// Running totals for the T1 acceptance checks. Read it from a debug screen or log it
    /// after walking around for a few seconds; `passes` should become true.
    var healthReport: FrameHealthReport { health.withLock { $0.report } }

    /// ARKit's latest tracking state in words, e.g. "normal" or "limited: initializing".
    var trackingStateDescription: String { trackingState.withLock { $0 } }
}

// MARK: - ARSessionDelegate

extension ARSessionManager: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let image = frame.capturedImage
        health.withLock {
            $0.record(
                timestamp: frame.timestamp,
                imageSize: (CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image)),
                cameraTransform: frame.camera.transform
            )
        }

        // Copy the handlers out so none of them runs while the lock is held. A handler
        // that subscribes or unsubscribes would otherwise deadlock.
        let current = handlers.withLock { Array($0.values) }
        for handler in current {
            handler(frame)
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let description = switch camera.trackingState {
        case .normal: "normal"
        case .notAvailable: "not available"
        case .limited(.initializing): "limited: initializing"
        case .limited(.excessiveMotion): "limited: moving too fast"
        case .limited(.insufficientFeatures): "limited: not enough detail in view"
        case .limited(.relocalizing): "limited: relocalizing"
        case .limited: "limited"
        }
        trackingState.withLock { $0 = description }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        runningState.withLock { $0 = false }
        log.error("ARKit session failed: \(error.localizedDescription, privacy: .public)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        // Usually the app went to the background or another app took the camera.
        log.notice("ARKit session interrupted")
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        log.notice("ARKit session interruption ended")
    }
}

enum ARSessionManagerError: LocalizedError {
    case worldTrackingUnsupported

    var errorDescription: String? {
        switch self {
        case .worldTrackingUnsupported:
            "This device does not support ARKit world tracking."
        }
    }
}
