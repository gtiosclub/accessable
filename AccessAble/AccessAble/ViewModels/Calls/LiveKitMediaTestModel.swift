#if DEBUG
import AVFoundation
import Foundation
import LiveKit
import Observation

/// Temporary transport test, independent of Firebase, matching, and the Calls placeholders.
/// MATCH-1 replaces this development token source with the authenticated Worker.
@MainActor
@Observable
final class LiveKitMediaTestModel {
    enum Role: String, CaseIterable, Identifiable {
        case caller, volunteer
        var id: String { rawValue }
    }
    enum Phase: Equatable { case idle, joining, connected, leaving }
    static let roomName = "accessable-call-test"

    private(set) var phase: Phase = .idle
    private(set) var message = "Choose Caller on one iPhone and Volunteer on the other."
    private(set) var localVideo: VideoTrack?
    private(set) var remoteVideo: VideoTrack?
    private(set) var peerCount = 0
    private(set) var remoteAudioCount = 0
    private(set) var microphonePublished = false
    private(set) var remoteIsSpeaking = false
    private(set) var connection = "Not connected"
    private(set) var guidanceWarning: String?

    @ObservationIgnored private let analyzer: ARSceneAnalyzer?
    @ObservationIgnored private var cameraToken: UUID?
    @ObservationIgnored private var room: Room?
    @ObservationIgnored private var joinTask: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var leaveTask: Task<Void, Never>?

    init(scene: any SceneObservationProviding) { analyzer = scene as? ARSceneAnalyzer }

    func start(role: Role) {
        guard phase == .idle else { return }
        guidanceWarning = nil
        phase = .joining
        joinTask = Task { [weak self] in
            guard let self else { return }
            await join(role: role)
        }
    }

    func stop() {
        guard phase != .idle, phase != .leaving else { return }
        phase = .leaving
        joinTask?.cancel()
        monitorTask?.cancel()
        leaveTask = Task { [weak self] in
            guard let self else { return }
            // A cancelled token request / permission prompt must finish before another join.
            await joinTask?.value
            await cleanUp()
            message = "Disconnected. You can join again."
            phase = .idle
            joinTask = nil
            leaveTask = nil
        }
    }

    private func join(role: Role) async {
        var stage = "connect"
        do {
            #if targetEnvironment(simulator)
            throw TestError.physicalPhonesRequired
            #endif
            // Injected by the Debug scheme, not bundled in the Release app's Info.plist.
            let id = (ProcessInfo.processInfo.environment["LIVEKIT_DEV_TOKEN_SERVER_ID"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !id.contains("$("), !id.contains("YOUR") else {
                throw TestError.missingConfiguration
            }
            message = "Checking microphone permission…"
            try await requestPermission(.audio)
            if role == .caller { try await requestPermission(.video) }
            try Task.checkCancellation()

            message = "Requesting a development token…"
            stage = "request a development token (check the ID, toggle and internet connection)"
            let credentials = try await DevelopmentTokenSource(id: id).fetch(TokenRequestOptions(
                roomName: Self.roomName,
                participantName: "Test \(role.rawValue)",
                participantIdentity: "\(role.rawValue)-\(UUID().uuidString.lowercased())"
            ))
            try Task.checkCancellation()
            // Pause the same manager used by CV; never create a second ARSession.
            cameraToken = try analyzer?.pauseForCall()
            let room = Room()
            self.room = room
            stage = "join the room (check the internet connection)"
            message = "Joining \(Self.roomName)…"
            try await room.connect(url: credentials.serverURL.absoluteString,
                                   token: credentials.participantToken)
            try Task.checkCancellation()

            stage = "publish the microphone (check microphone access in Settings)"
            try await room.localParticipant.setMicrophone(enabled: true)
            try Task.checkCancellation()
            if role == .caller {
                stage = "publish the rear camera (check camera access in Settings)"
                guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                else { throw TestError.noBackCamera }
                let publication = try await room.localParticipant.setCamera(
                    enabled: true, captureOptions: CameraCaptureOptions(device: camera, position: .back)
                )
                localVideo = publication?.track as? VideoTrack
            }
            try Task.checkCancellation()
            phase = .connected
            message = role == .caller ? "Sending rear camera + microphone." : "Sending microphone only. Waiting for caller video."
            refreshMedia()
            // Read-only diagnostics; receiving audio plays automatically through the SDK.
            monitorTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(300)) }
                    catch { return }
                    self?.refreshMedia()
                }
            }
        } catch {
            let wasCancelled = Task.isCancelled || phase == .leaving
            let failure = (error as? TestError)?.localizedDescription ?? "Couldn't \(stage). Disconnect and try again."
            await cleanUp()
            if !wasCancelled {
                message = failure
                phase = .idle
            }
        }
    }

    private func requestPermission(_ type: AVMediaType) async throws {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: type) else {
                throw TestError.permissionDenied(type == .audio ? "Microphone" : "Camera")
            }
        default: throw TestError.permissionDenied(type == .audio ? "Microphone" : "Camera")
        }
    }

    private func refreshMedia() {
        guard let room, phase == .connected else { return }
        connection = String(describing: room.connectionState)
        if room.connectionState == .disconnected {
            stop()
            return
        }
        let peers = Array(room.remoteParticipants.values)
        peerCount = peers.count
        remoteVideo = peers.flatMap { $0.videoTracks }.compactMap { $0.track as? VideoTrack }.first
        remoteAudioCount = peers.flatMap { $0.audioTracks }.filter { $0.track != nil }.count
        microphonePublished = room.localParticipant.audioTracks.contains { $0.track != nil && !$0.isMuted }
        remoteIsSpeaking = peers.contains { $0.isSpeaking }
    }

    private func cleanUp() async {
        monitorTask?.cancel()
        monitorTask = nil
        // SDK disconnect stops local capture and playback before AR is allowed to restart.
        if let room { await room.disconnect() }
        room = nil
        localVideo = nil
        remoteVideo = nil
        microphonePublished = false
        remoteAudioCount = 0
        remoteIsSpeaking = false
        peerCount = 0
        connection = "Not connected"
        if let token = cameraToken {
            cameraToken = nil
            do { try analyzer?.resumeAfterCall(token) }
            catch { guidanceWarning = "Call ended, but camera guidance could not restart. Reopen the guidance screen." }
        }
    }

    private enum TestError: LocalizedError {
        case missingConfiguration, physicalPhonesRequired, noBackCamera, permissionDenied(String)
        var errorDescription: String? {
            switch self {
            case .missingConfiguration: "Set LIVEKIT_DEV_TOKEN_SERVER_ID in AccessAble/Config/Secrets.xcconfig, then rebuild."
            case .physicalPhonesRequired: "Run this test on two physical iPhones, not the Simulator."
            case .noBackCamera: "No rear camera is available on this device."
            case .permissionDenied(let name): "\(name) access is required. Enable it for AccessAble in iPhone Settings."
            }
        }
    }
}
#endif
