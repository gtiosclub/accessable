import ARKit
import CoreVideo
import Foundation
import Synchronization
import os

/// Owner: Computer Vision (1.4 / tasks T1, T2). The app's one ARKit session.
///
/// iOS gives the camera to one session at a time, so every module that needs camera frames
/// or the device pose subscribes here rather than running its own `ARSession`.
///
/// The session runs gravity-aligned world tracking (world +Y is up, which the floor fit and
/// walking corridor assume) and, on LiDAR devices, `sceneDepth` (T2). Smoothed scene depth
/// is deliberately not requested: it averages several frames, so it lags behind anything
/// moving toward the user, and nothing in the pipeline needs it.
///
/// Threading: frames arrive on a private serial queue, one at a time and in order, and
/// handlers run on that queue. Handlers must return quickly and must not keep the `ARFrame`
/// — ARKit reuses a small pool of frame buffers and stalls when they are retained. Heavy
/// work belongs behind `LatestOnlyProcessor`.
///
/// `@unchecked Sendable` because `ARSession` and `ARFrame` are not `Sendable`. It is safe
/// because all mutable state is behind a `Mutex`, the session is only configured from the
/// main actor, and frames are only delivered on `frameQueue`.
final class ARSessionManager: NSObject, @unchecked Sendable {
    typealias FrameHandler = @Sendable (ARFrame) -> Void

    struct Subscription: Hashable, Sendable {
        fileprivate let id: UUID
    }

    /// Exposed so a preview view (`ARSCNView`) can render this exact session. Touch it only
    /// from the main actor.
    let session = ARSession()

    /// False in the Simulator and on devices without world tracking.
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    /// True on devices with a LiDAR scanner, where frames carry `sceneDepth`.
    let isDepthSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)

    private let frameQueue = DispatchQueue(label: "AccessAble.ARSessionManager.frames", qos: .userInteractive)
    private let handlers = Mutex<[UUID: FrameHandler]>([:])
    private let health = Mutex(FrameHealthCheck())
    private let trackingState = Mutex("not started")
    private let log = Logger(subsystem: "AccessAble", category: "ARSessionManager")

    // MARK: - Lifecycle

    /// Starts world tracking. Calling it while running restarts tracking from scratch.
    @MainActor
    func start() throws {
        guard ARWorldTrackingConfiguration.isSupported else {
            throw ARSessionManagerError.worldTrackingUnsupported
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []
        if isDepthSupported {
            configuration.frameSemantics.insert(.sceneDepth)
        } else {
            log.notice("sceneDepth unsupported; running without LiDAR depth")
        }

        health.withLock { $0.reset() }
        session.delegate = self
        session.delegateQueue = frameQueue
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    /// Pauses the session. Subscribers stay registered and get frames again after `start()`.
    @MainActor
    func stop() {
        session.pause()
    }

    // MARK: - Subscribing to frames

    /// Calls `handler` on the frame queue with every new frame until the subscription is removed.
    @discardableResult
    func addFrameHandler(_ handler: @escaping FrameHandler) -> Subscription {
        let id = UUID()
        handlers.withLock { $0[id] = handler }
        return Subscription(id: id)
    }

    func removeFrameHandler(_ subscription: Subscription) {
        handlers.withLock { $0[subscription.id] = nil }
    }

    // MARK: - Diagnostics

    /// Running totals for the T1 acceptance checks; `passes` becomes true once frames are
    /// flowing and the camera has moved. Shown on the Live detection screen.
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

        // Copied out so no handler runs while the lock is held; a handler that
        // unsubscribes would otherwise deadlock.
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
        log.error("ARKit session failed: \(error.localizedDescription, privacy: .public)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
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
            "This device does not support ARKit world tracking, so camera guidance is unavailable."
        }
    }
}
