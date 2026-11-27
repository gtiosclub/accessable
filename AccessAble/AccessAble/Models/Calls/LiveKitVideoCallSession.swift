import AVFoundation
import Foundation
import LiveKit
import OSLog

private let log = Logger(subsystem: "AccessAble", category: "Call")

/// Owner: Calls (VOLUNTEER-5). The real `VideoCallSession`: one LiveKit room per call.
///
/// Camera rule (Docs/Calls/Overview.md): `ARSessionManager` stays the only camera owner. AR pauses
/// before LiveKit takes the camera and resumes only after LiveKit has let go of it.
@MainActor
final class LiveKitVideoCallSession: VideoCallSession {
    private nonisolated let broadcaster = Broadcaster<CallState>(replaysLatest: true)
    private let auth: any AuthService
    private let pauseCamera: @MainActor () throws -> UUID?
    private let resumeCamera: @MainActor (UUID) throws -> Void

    private var room: Room?
    private var cameraTrack: LocalVideoTrack?
    private var cameraPosition: AVCaptureDevice.Position = .back
    private var cameraToken: UUID?
    private var monitor: Task<Void, Never>?
    /// Whether the other person has joined, so their leaving can be noticed.
    private var sawPartner = false
    private var isJoining = false
    private var connectionGeneration = UUID()
    private var partnerDeadline: Date?
    /// When the other person was last missing from the room, so a short gap isn't taken for leaving.
    private var partnerMissingSince: Date?
    /// How long they may be gone, for example while their phone switches from Wi-Fi to cellular.
    private static let partnerGoneGrace: TimeInterval = 10
    /// Sent just before hanging up, so the other phone ends the call at once instead of waiting
    /// out `partnerGoneGrace`. Either side hanging up ends it for both.
    nonisolated static let hangUpTopic = "call.hangup"
    private var hangUpListener: HangUpListener?

    /// Main-actor read access for the other person's video; never exposes tokens or the Room.
    /// Nil while they have their camera off.
    var remoteVideoTrack: VideoTrack? {
        room?.remoteParticipants.values.flatMap { $0.videoTracks }
            .filter { !$0.isMuted }
            .compactMap { $0.track as? VideoTrack }.first
    }

    /// This phone's own camera while it's on: behind the caller's controls, or in the volunteer's corner box.
    var localVideoTrack: VideoTrack? {
        guard let cameraTrack, !cameraTrack.isMuted else { return nil }
        return cameraTrack
    }

    init(
        auth: any AuthService,
        pauseCamera: @escaping @MainActor () throws -> UUID?,
        resumeCamera: @escaping @MainActor (UUID) throws -> Void
    ) {
        self.auth = auth
        self.pauseCamera = pauseCamera
        self.resumeCamera = resumeCamera
        broadcaster.send(.idle)
    }

    // MARK: - VideoCallSession

    nonisolated func states() -> AsyncStream<CallState> { broadcaster.stream() }
    nonisolated func connect(with ticket: CallTicket) async throws { try await join(ticket) }
    nonisolated func disconnect() async { await leave(.hungUp) }
    nonisolated func setMicrophoneMuted(_ muted: Bool) async throws { try await setMuted(muted) }
    nonisolated func flipCamera() async throws { try await switchCamera() }
    nonisolated func setFlashlight(_ on: Bool) async throws { try await setConfirmedTorch(on) }
    nonisolated func setCameraEnabled(_ on: Bool) async throws { try await setCamera(on) }

    // MARK: - Joining and leaving

    private func join(_ ticket: CallTicket) async throws {
        guard room == nil, !isJoining else { throw CallSessionError.alreadyInCall }
        guard let url = LiveKitConfig.serverURL else { throw CallSessionError.notConfigured }
        guard !ticket.isExpired() else { throw CallSessionError.expiredTicket }
        isJoining = true
        defer { isJoining = false }
        let generation = UUID()
        connectionGeneration = generation
        var attemptedRoom: Room?
        broadcaster.send(.connecting)
        do {
            // The caller sends their back camera; the volunteer sends only their voice.
            let uid = await auth.currentUser()?.id
            try checkJoin(generation)
            guard uid == ticket.callerID || uid == ticket.volunteerID else { throw CallSessionError.notParticipant }
            let isCaller = uid == ticket.callerID
            try await requestPermission(.audio)
            try checkJoin(generation)
            if isCaller { try await requestPermission(.video) }
            try checkJoin(generation)
            configureAudio()
            // Camera rule: AR lets go of the camera before LiveKit takes it.
            if isCaller { cameraToken = try pauseCamera() }

            let room = Room()
            attemptedRoom = room
            self.room = room
            let listener = HangUpListener { [weak self] in
                Task { @MainActor in await self?.leave(.remoteLeft) }
            }
            room.add(delegate: listener)
            hangUpListener = listener
            try await room.connect(url: url.absoluteString, token: ticket.token)
            try checkJoin(generation)
            try await room.localParticipant.setMicrophone(enabled: true)
            try checkJoin(generation)
            if isCaller { try await publishCamera(position: .back) }
            try checkJoin(generation)

            // Connected means the other person is here too; until then the call stays connecting.
            sawPartner = !room.remoteParticipants.isEmpty
            // Connected means the other person is here too; until then the call stays connecting.
            sawPartner = !room.remoteParticipants.isEmpty
            partnerDeadline = Date().addingTimeInterval(30)
            if sawPartner { broadcaster.send(.connected) }
            startMonitoring()
        } catch is CancellationError {
            log.notice("call join cancelled")
            await cleanUp()
            broadcaster.send(.ended(.hungUp))
            throw CancellationError()
        } catch {
            // The screen only says "couldn't connect"; the real reason goes to the console.
            log.error("call join failed: \(String(describing: error), privacy: .public)")
            // An in-flight room.connect may complete after disconnect invalidated this join.
            // Stop that local Room even if it was already removed from self.room.
            if let attemptedRoom { await attemptedRoom.disconnect() }
            await cleanUp()
            if connectionGeneration == generation, !Task.isCancelled {
                broadcaster.send(.failed((error as? LocalizedError)?.errorDescription ?? "Couldn't connect the call."))
            }
            throw error
        }
    }

    private func leave(_ reason: CallState.EndReason) async {
        guard room != nil || cameraToken != nil || isJoining else { return }
        connectionGeneration = UUID()
        if reason == .hungUp, let room { await Self.sendHangUp(in: room) }
        await cleanUp()
        broadcaster.send(.ended(reason))
    }

    private func cleanUp() async {
        monitor?.cancel()
        monitor = nil
        try? setTorch(false)
        // Disconnecting stops LiveKit's camera and microphone.
        if let room { await room.disconnect() }
        room = nil
        hangUpListener = nil
        cameraTrack = nil
        cameraPosition = .back
        sawPartner = false
        partnerDeadline = nil
        partnerMissingSince = nil
        // Camera rule: AR (and CV with it) resumes only after LiveKit has let go.
        if let token = cameraToken {
            cameraToken = nil
            try? resumeCamera(token)
        }
    }

    /// Notices the other person leaving or the connection dropping.
    private func startMonitoring() {
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                await self.checkRoom()
            }
        }
    }

    private func checkRoom() async {
        guard let room else { return }
        if room.connectionState == .disconnected {
            await leave(.remoteLeft)
        } else if room.connectionState == .reconnecting {
            // This phone is reconnecting: the room looks empty until it's back, so wait.
            return
        } else if !room.remoteParticipants.isEmpty {
            partnerMissingSince = nil
            if !sawPartner {
                sawPartner = true
                broadcaster.send(.connected)
            }
        } else if sawPartner {
            // They may be reconnecting; only a longer absence ends the call.
            let since = partnerMissingSince ?? Date()
            partnerMissingSince = since
            if Date().timeIntervalSince(since) >= Self.partnerGoneGrace { await leave(.remoteLeft) }
        } else if let partnerDeadline, Date() >= partnerDeadline {
            // The other side failed before joining: don't strand a volunteer inCall forever.
            await leave(.unanswered)
        }
    }

    private func checkJoin(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard connectionGeneration == generation else { throw CancellationError() }
    }

    /// Tells the other phone this is a hang-up, waiting at most a second so leaving is never stuck.
    private static func sendHangUp(in room: Room) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await room.localParticipant.publish(
                    data: Data("hangup".utf8), options: DataPublishOptions(topic: hangUpTopic, reliable: true))
            }
            group.addTask { try? await Task.sleep(for: .seconds(1)) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Audio

    /// LiveKit sets up the audio session itself; this only tells it how:
    /// voice chat, through the speaker, with Bluetooth headsets allowed.
    private func configureAudio() {
        AudioManager.shared.sessionConfiguration = AudioSessionConfiguration(
            category: .playAndRecord,
            categoryOptions: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP],
            mode: .voiceChat
        )
        AudioManager.shared.isSpeakerOutputPreferred = true
    }

    // MARK: - Controls

    private func setMuted(_ muted: Bool) async throws {
        guard let room else { throw CallSessionError.notConnected }
        try await room.localParticipant.setMicrophone(enabled: !muted)
    }

    private func publishCamera(position: AVCaptureDevice.Position) async throws {
        guard let room else { throw CallSessionError.notConnected }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        else { throw CallSessionError.noCamera }
        let publication = try await room.localParticipant.setCamera(
            enabled: true, captureOptions: CameraCaptureOptions(device: device, position: position)
        )
        cameraTrack = publication?.track as? LocalVideoTrack
        cameraPosition = position
    }

    /// Off mutes the camera track; on publishes it again. A volunteer's first "on" asks for the
    /// camera, takes it from AR (the camera rule) and starts the front camera.
    private func setCamera(_ on: Bool) async throws {
        guard let room else { throw CallSessionError.notConnected }
        if !on {
            try? setTorch(false)
            _ = try await room.localParticipant.setCamera(enabled: false)
            return
        }
        if cameraTrack == nil {
            try await requestPermission(.video)
            if cameraToken == nil { cameraToken = try pauseCamera() }
            try await publishCamera(position: .front)
        } else {
            _ = try await room.localParticipant.setCamera(enabled: true)
        }
    }

    private func switchCamera() async throws {
        guard let capturer = cameraTrack?.capturer as? CameraCapturer else { throw CallSessionError.noCamera }
        // Only the back camera has a light; turn it off before switching away.
        try? setTorch(false)
        _ = try await capturer.switchCameraPosition()
        cameraPosition = cameraPosition == .back ? .front : .back
    }

    /// Sets the light and waits until the camera reports it, for up to 2 seconds. Right after
    /// joining, LiveKit's capture session may still be starting, and starting it can turn the
    /// light back off, so the screen would say "Flashlight on" while the volunteer sees dark.
    private func setConfirmedTorch(_ on: Bool) async throws {
        for _ in 0..<10 {
            try setTorch(on)
            guard on else { return }
            try await Task.sleep(for: .milliseconds(200))
            if AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)?.isTorchActive == true {
                return
            }
        }
        throw CallSessionError.noFlashlight
    }

    private func setTorch(_ on: Bool) throws {
        guard cameraTrack != nil, cameraPosition == .back,
              let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              device.hasTorch
        else {
            if on { throw CallSessionError.noFlashlight }
            return
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.torchMode = on ? .on : .off
    }

    // MARK: - Permissions

    private func requestPermission(_ type: AVMediaType) async throws {
        let name = type == .audio ? "Microphone" : "Camera"
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: type) else { throw CallSessionError.permissionDenied(name) }
        default:
            throw CallSessionError.permissionDenied(name)
        }
    }
}

/// Hears the other phone's hang-up message.
private final class HangUpListener: NSObject, RoomDelegate, @unchecked Sendable {
    private let onHangUp: @Sendable () -> Void

    init(onHangUp: @escaping @Sendable () -> Void) {
        self.onHangUp = onHangUp
    }

    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data,
              forTopic topic: String, encryptionType: EncryptionType) {
        guard participant != nil, topic == LiveKitVideoCallSession.hangUpTopic else { return }
        onHangUp()
    }
}

enum CallSessionError: LocalizedError, Sendable {
    case notParticipant
    case notConfigured, alreadyInCall, expiredTicket, notConnected, noCamera, noFlashlight
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .notParticipant: "Sign in to the account that belongs to this call."
        case .notConfigured: "Calls aren't set up on this phone. Add LIVEKIT_URL to Secrets.xcconfig."
        case .alreadyInCall: "A call is already in progress."
        case .expiredTicket: "This call request expired. Try calling again."
        case .notConnected: "The call isn't connected."
        case .noCamera: "No camera is available."
        case .noFlashlight: "This camera has no flashlight."
        case .permissionDenied(let name): "\(name) access is needed for calls. Turn it on for AccessAble in Settings."
        }
    }
}
