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
/// moving toward the user, and nothing in the pipeline needs it. During trips, where Apple
/// has imagery, it geo-tracks instead (AR-2); +Y is still up there.
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
    /// Whether the classified mesh (T36) is wanted. Building it is heavy enough to pull the
    /// camera from 60 to about 34 fps and slow every analyzed frame, and only "take me to…"
    /// uses it (to find doors), so it runs only while that is active.
    private let wantsMesh = Mutex(false)
    @MainActor private var cameraOwnership = CameraOwnershipState()
    private let pausedForCall = Mutex(false)
    var isPausedForCall: Bool { pausedForCall.withLock { $0 } }
    /// Whether the next `start()` geo-tracks (AR-2): set for trips, only where geo-tracking is available.
    private let wantsGeoTracking = Mutex(false)
    /// The last availability answer, so `start()` never waits for one.
    private let geoAvailability = Mutex<GeoAvailability?>(nil)
    /// The availability check in flight, so overlapping requests share it.
    private let geoAvailabilityCheck = Mutex<Task<Void, Never>?>(nil)
    /// What the running session uses; nil while stopped.
    private let runningTracking = Mutex<SessionTracking?>(nil)
    private let geoBroadcaster = Broadcaster<GeoTrackingUpdate>()
    /// Frame timestamp of the last geo update sent.
    private let lastGeoUpdate = Mutex<TimeInterval>(-.infinity)
    private let log = Logger(subsystem: "AccessAble", category: "ARSessionManager")

    /// How long ARKit is given to relocalize after an interruption before guidance is
    /// declared stopped (T27). Relocalization normally lands in a second or two; past this
    /// the user is standing still waiting for guidance that is not coming back.
    private static let relocalizationTimeout: Duration = .seconds(5)

    // MARK: - Lifecycle

    /// Starts world tracking, or geo-tracking when it is wanted and the mesh isn't. Calling it
    /// while running restarts tracking from scratch.
    @MainActor
    func start() throws {
        guard ARWorldTrackingConfiguration.isSupported else {
            setStatus(.unavailable)
            throw ARSessionManagerError.worldTrackingUnsupported
        }
        // New AR clients can register during a call, but must not take LiveKit's camera.
        guard cameraOwnership.requestARStart() else { return }

        let wantsMesh = wantsMesh.withLock { $0 }
        let wantsGeo = wantsGeoTracking.withLock { $0 }
        let geoAvailable = geoAvailability.withLock { known in
            known.flatMap { $0.isFresh(at: .now) ? $0.isAvailable : nil }
        }
        // Unknown means world tracking now; the answer is ready for the next start (after a call, or the next trip).
        if wantsGeo, geoAvailable == nil { refreshGeoAvailability() }
        let tracking = SessionTracking.choose(geoWanted: wantsGeo, geoAvailable: geoAvailable, meshWanted: wantsMesh)
        let configuration: ARConfiguration = switch tracking {
        case .world: worldTrackingConfiguration(mesh: wantsMesh)
        case .geo: geoTrackingConfiguration()
        }

        health.withLock { $0.reset() }
        cancelRecoveryTimeout()
        runningTracking.withLock { $0 = tracking }
        lastGeoUpdate.withLock { $0 = -.infinity }
        session.delegate = self
        session.delegateQueue = frameQueue
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        setStatus(.running)
    }

    private func worldTrackingConfiguration(mesh: Bool) -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []
        pinWideCamera(configuration, from: ARWorldTrackingConfiguration.supportedVideoFormats)
        if isDepthSupported {
            configuration.frameSemantics.insert(.sceneDepth)
        } else {
            log.notice("sceneDepth unsupported; running without LiDAR depth")
        }
        // T36: classified mesh for doors and windows, only while something needs it
        configuration.sceneReconstruction = meshReconstruction(wanted: mesh)
        return configuration
    }

    /// World +Y is still up (east-up-south), so the floor fit and corridor hold. It has no
    /// mesh, which is why `SessionTracking.choose` keeps world tracking while doors are wanted.
    private func geoTrackingConfiguration() -> ARGeoTrackingConfiguration {
        let configuration = ARGeoTrackingConfiguration()
        configuration.planeDetection = []
        pinWideCamera(configuration, from: ARGeoTrackingConfiguration.supportedVideoFormats)
        if ARGeoTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        } else {
            log.notice("sceneDepth unsupported with geo-tracking; running without LiDAR depth")
        }
        return configuration
    }

    /// The back wide-angle camera's format, pinned so the preview never changes lens.
    /// ARKit's default is usually this camera already; pinning it makes that a guarantee,
    /// and the wide camera is the one LiDAR depth is registered to. Prefers ARKit's default
    /// format when it is on that camera, so resolution and frame rate stay the same.
    static func primaryVideoFormat(in formats: [ARConfiguration.VideoFormat]) -> ARConfiguration.VideoFormat? {
        let isWideBack = { (format: ARConfiguration.VideoFormat) in
            format.captureDeviceType == .builtInWideAngleCamera && format.captureDevicePosition == .back
        }
        if let first = formats.first, isWideBack(first) { return first }
        return formats.first(where: isWideBack)
    }

    private func pinWideCamera(_ configuration: ARConfiguration, from formats: [ARConfiguration.VideoFormat]) {
        guard let format = Self.primaryVideoFormat(in: formats) else { return }
        configuration.videoFormat = format
        log.notice("camera: back wide-angle, \(Int(format.imageResolution.width), privacy: .public)x\(Int(format.imageResolution.height), privacy: .public) at \(format.framesPerSecond, privacy: .public) fps")
    }

    /// Turns the classified mesh on or off without restarting tracking. While the session
    /// isn't running it only records the wish, and the next `start()` applies it: re-running
    /// a paused session here and again in `start()` made the preview visibly jump.
    ///
    /// - Returns: true when tracking had to restart from scratch: the mesh was wanted while
    ///   geo-tracking, which can't build one, so the session went back to world tracking.
    @MainActor
    @discardableResult
    func setMeshReconstruction(_ enabled: Bool) -> Bool {
        let changed = wantsMesh.withLock { wanted in
            defer { wanted = enabled }
            return wanted != enabled
        }
        guard cameraOwnership.callOwner == nil, changed,
              let running = runningTracking.withLock({ $0 })
        else { return false }
        if enabled, running == .geo {
            log.notice("mesh wanted while geo-tracking; switching to world tracking")
            try? start()
            return true
        }
        guard let configuration = session.configuration?.copy() as? ARWorldTrackingConfiguration else { return false }
        configuration.sceneReconstruction = meshReconstruction(wanted: enabled)
        // Re-running without .resetTracking keeps the world; dropping the mesh's anchors
        // stops stale doors from being found after it is switched off.
        session.run(configuration, options: enabled ? [] : [.removeExistingAnchors])
        return false
    }

    // MARK: - Geo-tracking (AR-2)

    /// False in the Simulator and on devices without an A12 or later chip and GPS.
    static var isGeoTrackingSupported: Bool { ARGeoTrackingConfiguration.isSupported }

    /// Whether the next `start()` should geo-track. It doesn't restart a running session:
    /// that would reset the world CV has mapped. A call pauses and restarts the session, so
    /// the choice carries over the call. Never waits: it only geo-tracks once
    /// `refreshGeoAvailability()` has an answer, which this starts if needed.
    @MainActor
    func setGeoTracking(_ wanted: Bool) {
        wantsGeoTracking.withLock { $0 = wanted }
        if wanted { refreshGeoAvailability() }
    }

    /// What the running session uses; nil while stopped.
    var tracking: SessionTracking? { runningTracking.withLock { $0 } }

    /// Checks in the background whether Apple has geo-tracking imagery here, unless a recent
    /// answer is kept or a check is already running. Returns at once.
    func refreshGeoAvailability() {
        guard Self.isGeoTrackingSupported,
              geoAvailability.withLock({ $0?.isFresh(at: .now) }) != true
        else { return }
        geoAvailabilityCheck.withLock { running in
            guard running == nil else { return }
            running = Task { [weak self] in
                let available = await Self.isGeoTrackingAvailableHere()
                guard let self else { return }
                self.geoAvailability.withLock { $0 = GeoAvailability(isAvailable: available, checkedAt: .now) }
                self.geoAvailabilityCheck.withLock { $0 = nil }
                self.log.notice("geo-tracking available here: \(available, privacy: .public)")
            }
        }
    }

    /// Whether Apple has geo-tracking imagery where the phone is. Can take seconds, so
    /// nothing the camera waits on calls it: use `refreshGeoAvailability()`.
    static func isGeoTrackingAvailableHere() async -> Bool {
        guard isGeoTrackingSupported else { return false }
        return await withCheckedContinuation { continuation in
            ARGeoTrackingConfiguration.checkAvailability { available, _ in continuation.resume(returning: available) }
        }
    }

    /// Position and heading about once a second while geo-tracking; nothing otherwise.
    func geoTrackingUpdates() -> AsyncStream<GeoTrackingUpdate> {
        geoBroadcaster.stream(bufferingPolicy: .bufferingNewest(4))
    }

    /// Runs on the frame queue. Copies what it needs, so the frame isn't kept.
    private func publishGeoUpdate(from frame: ARFrame, in session: ARSession) {
        guard let status = frame.geoTrackingStatus else { return }
        let due = lastGeoUpdate.withLock { last in
            guard frame.timestamp - last >= 1 else { return false }
            last = frame.timestamp
            return true
        }
        guard due else { return }

        let transform = frame.camera.transform
        var update = GeoTrackingUpdate(
            state: GeoTrackingUpdate.State(status.state),
            accuracy: GeoTrackingUpdate.Accuracy(status.accuracy),
            timestamp: .now
        )
        guard update.state == .localized else {
            geoBroadcaster.send(update)
            return
        }
        update.heading = GeoTrackingUpdate.heading(cameraTransform: transform)
        let position = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        session.getGeoLocation(forPoint: position) { [geoBroadcaster, update] coordinate, altitude, error in
            guard error == nil else { return }
            var located = update
            located.coordinate = GeoCoordinate(coordinate)
            located.altitude = altitude
            geoBroadcaster.send(located)
        }
    }

    private func meshReconstruction(wanted: Bool) -> ARConfiguration.SceneReconstruction {
        wanted && ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
            ? .meshWithClassification : []
    }

    /// Pauses the session. Subscribers stay registered and get frames again after `start()`.
    @MainActor
    func stop() {
        cameraOwnership.requestARStop()
        cancelRecoveryTimeout()
        session.pause()
        runningTracking.withLock { $0 = nil }
        setStatus(.idle)
    }

    /// Pauses this exact shared session without changing the analyzer's client count.
    @MainActor
    func beginCallCameraOwnership() throws -> UUID {
        let token = try cameraOwnership.acquireForCall()
        pausedForCall.withLock { $0 = true }
        cancelRecoveryTimeout()
        session.pause()
        setStatus(.interrupted)
        return token
    }

    /// Call only after LiveKit has stopped its tracks. Restart only if AR still has clients.
    @MainActor
    func endCallCameraOwnership(_ token: UUID) throws {
        guard let shouldRestart = cameraOwnership.releaseFromCall(token) else { return }
        pausedForCall.withLock { $0 = false }
        if shouldRestart {
            do { try start() }
            catch {
                setStatus(.stopped(reason: error.localizedDescription))
                throw error
            }
        } else {
            setStatus(.idle)
        }
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
        guard !pausedForCall.withLock({ $0 }) else { return }
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
        publishGeoUpdate(from: frame, in: session)
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        guard !pausedForCall.withLock({ $0 }) else { return }
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
        guard !pausedForCall.withLock({ $0 }) else { return }
        log.error("ARKit session failed: \(error.localizedDescription, privacy: .public)")
        cancelRecoveryTimeout()
        setStatus(.stopped(reason: error.localizedDescription))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        guard !pausedForCall.withLock({ $0 }) else { return }
        log.notice("ARKit session interrupted")
        cancelRecoveryTimeout()
        setStatus(.interrupted)
        interruptionHandler.withLock { $0 }?(true)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        guard !pausedForCall.withLock({ $0 }) else { return }
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
