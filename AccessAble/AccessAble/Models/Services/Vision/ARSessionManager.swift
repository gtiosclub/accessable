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
    private let status = Mutex(GuidanceStatus.idle)
    private let statusBroadcaster = Broadcaster<GuidanceStatus>(replaysLatest: true)
    private let recoveryTimeout = Mutex<Task<Void, Never>?>(nil)
    private let interruptionHandler = Mutex<(@Sendable (_ isInterrupted: Bool) -> Void)?>(nil)
    private let log = Logger(subsystem: "AccessAble", category: "ARSessionManager")

    /// How long ARKit is given to relocalize after an interruption before guidance is
    /// declared stopped (T27). Relocalization normally lands in a second or two; past this
    /// the user is standing still waiting for guidance that is not coming back.
    private static let relocalizationTimeout: Duration = .seconds(5)

    // MARK: - Lifecycle

    /// Starts world tracking. Calling it while running restarts tracking from scratch.
    @MainActor
    func start() throws {
        guard ARWorldTrackingConfiguration.isSupported else {
            setStatus(.unavailable)
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
        // T36: classified mesh for doors and windows, where the device supports it
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        }

        health.withLock { $0.reset() }
        cancelRecoveryTimeout()
        session.delegate = self
        session.delegateQueue = frameQueue
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        setStatus(.running)
    }

    /// Pauses the session. Subscribers stay registered and get frames again after `start()`.
    @MainActor
    func stop() {
        cancelRecoveryTimeout()
        session.pause()
        setStatus(.idle)
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

    /// Called when the system takes the camera away (phone locked, app in the background, a
    /// call) and when it gives it back. Not called for `stop()`.
    func setInterruptionHandler(_ handler: (@Sendable (_ isInterrupted: Bool) -> Void)?) {
        interruptionHandler.withLock { $0 = handler }
    }

    // MARK: - Diagnostics

    /// Running totals for the T1 acceptance checks; `passes` becomes true once frames are
    /// flowing and the camera has moved. Shown on the Live detection screen.
    var healthReport: FrameHealthReport { health.withLock { $0.report } }

    /// ARKit's latest tracking state in words, e.g. "normal" or "limited: initializing".
    var trackingStateDescription: String { trackingState.withLock { $0 } }

    // MARK: - Guidance status (T27)

    /// Whether camera guidance is running right now. The session is the only thing that
    /// observes this, and it outlives every screen, so it is the one source of truth.
    var guidanceStatus: GuidanceStatus { status.withLock { $0 } }

    /// Status changes, starting with the current value so a screen that appears later is
    /// not left guessing. Only changes are sent; the same status twice is not republished.
    func guidanceStatuses() -> AsyncStream<GuidanceStatus> {
        statusBroadcaster.stream(bufferingPolicy: .bufferingNewest(4))
    }

    private func setStatus(_ newStatus: GuidanceStatus) {
        let changed = status.withLock { current in
            guard current != newStatus else { return false }
            current = newStatus
            return true
        }
        guard changed else { return }
        log.notice("guidance status: \(String(describing: newStatus), privacy: .public)")
        statusBroadcaster.send(newStatus)
    }

    /// ARKit relocalizes by itself once an interruption ends, and reports success by
    /// returning to normal tracking. Nothing reports failure, so waiting is the only way
    /// to notice that guidance is not coming back.
    private func scheduleRecoveryTimeout() {
        let task = Task { [weak self] in
            try? await Task.sleep(for: Self.relocalizationTimeout)
            guard !Task.isCancelled, let self, case .recovering = self.guidanceStatus else { return }
            self.setStatus(.stopped(reason: "Tracking could not be recovered."))
        }
        let previous = recoveryTimeout.withLock { stored in
            defer { stored = task }
            return stored
        }
        previous?.cancel()
    }

    private func cancelRecoveryTimeout() {
        let previous = recoveryTimeout.withLock { stored in
            defer { stored = nil }
            return stored
        }
        previous?.cancel()
    }
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

        // Normal tracking is the only signal ARKit gives that relocalization worked.
        if case .normal = camera.trackingState {
            switch guidanceStatus {
            case .interrupted, .recovering:
                cancelRecoveryTimeout()
                setStatus(.running)
            case .idle, .running, .stopped, .unavailable:
                break
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        log.error("ARKit session failed: \(error.localizedDescription, privacy: .public)")
        cancelRecoveryTimeout()
        setStatus(.stopped(reason: error.localizedDescription))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        log.notice("ARKit session interrupted")
        cancelRecoveryTimeout()
        setStatus(.interrupted)
        interruptionHandler.withLock { $0 }?(true)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        log.notice("ARKit session interruption ended")
        // Not the same as "tracking works again": ARKit now has to recognize where it is,
        // and until it does, world coordinates mean nothing.
        setStatus(.recovering)
        scheduleRecoveryTimeout()
        interruptionHandler.withLock { $0 }?(false)
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

/// Whether camera guidance is actually running, for the screens that have to say so out
/// loud (T27).
///
/// One value rather than three loose callbacks: `sessionWasInterrupted`,
/// `sessionInterruptionEnded` and `didFailWithError` are transitions in a single lifecycle,
/// and reacting to each as it arrives produces contradictions — "guidance stopped" spoken
/// after the session already came back, because the speech was still queued behind
/// something else.
enum GuidanceStatus: Equatable, Sendable {
    /// Before `start()`, and after `stop()`.
    case idle
    /// The session is running; frames are flowing.
    case running
    /// Backgrounded, a phone call, or Siri. ARKit delivers nothing at all until it ends.
    case interrupted
    /// The interruption ended and ARKit is relocalizing. The remembered floor and occupancy
    /// map are anchored in world coordinates, so they hold only if relocalization succeeds.
    case recovering
    /// Guidance has stopped and will not come back on its own.
    case stopped(reason: String)
    /// No ARKit world tracking on this device.
    case unavailable
}

extension GuidanceStatus {
    /// What to say on moving from `previous` into this status; nil when there is nothing
    /// worth saying.
    ///
    /// An interruption and its end are announced by `ARSceneAnalyzer`'s interruption
    /// handler ("Camera paused. Obstacle warnings are off." / "Camera back on…"), so they
    /// say nothing here; saying them twice would bury the next warning. What this adds is
    /// guidance failing to come back, and coming back after it had stopped.
    func announcement(after previous: GuidanceStatus) -> AnnouncementEvent? {
        switch (previous, self) {
        case (.stopped, .running):
            AnnouncementEvent(
                category: .system,
                priority: .high,
                text: "Camera guidance restored.",
                source: .system,
                dedupKey: "guidance-restored"
            )
        case (_, .stopped(let reason)):
            AnnouncementEvent(
                category: .system,
                priority: .critical,
                text: "Camera guidance has stopped. \(reason)",
                source: .system,
                dedupKey: "guidance-stopped"
            )
        case (_, .unavailable):
            AnnouncementEvent(
                category: .system,
                priority: .critical,
                text: "Camera guidance is unavailable on this device.",
                source: .system,
                dedupKey: "guidance-unavailable"
            )
        default:
            nil
        }
    }

    /// Whether the display must be kept awake. Interrupted and recovering count: guidance is
    /// expected back within seconds, and letting the screen sleep in between would stop the
    /// camera for good.
    var keepsScreenAwake: Bool {
        switch self {
        case .running, .interrupted, .recovering: true
        case .idle, .stopped, .unavailable: false
        }
    }
}
