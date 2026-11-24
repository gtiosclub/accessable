import AVFoundation
import Foundation
import Observation

/// Owner: Calls (VOLUNTEER-5; matching from VOLUNTEER-6; connecting and failures from VOLUNTEER-7).
/// One call, from ringing volunteers to hanging up.
@MainActor
@Observable
final class CallViewModel {
    private(set) var state: CallState = .idle
    /// What the screen shows while ringing, e.g. "No answer. Trying another volunteer."
    private(set) var progressText = "Calling a volunteer"
    /// Why the last attempt failed, so the screen can offer the right way out.
    private(set) var failure: CallFailure?
    private(set) var isMuted = false
    private(set) var isUsingBackCamera = true
    private(set) var isFlashlightOn = false
    private(set) var controlError: String?
    /// The volunteer who answered, once known. Nil while ringing, or if it isn't the one picked.
    private(set) var volunteerName: String?

    @ObservationIgnored private let services: AppServices
    /// The volunteer the caller picked, rung first. Nil for "Call a volunteer".
    @ObservationIgnored private let preferred: Volunteer?
    @ObservationIgnored private var ticket: CallTicket?
    /// Ringing volunteers one at a time; cancelled when the caller hangs up or leaves the screen.
    @ObservationIgnored private var placing: Task<Void, Never>?
    /// The session replays its last state, which may be the end of an earlier call;
    /// states are only taken once this call has started connecting.
    @ObservationIgnored private var hasStartedConnecting = false

    init(services: AppServices, volunteer: Volunteer?) {
        self.services = services
        self.preferred = volunteer
    }

    var title: String { volunteerName ?? "Volunteer call" }

    /// What the screen shows. Spoken too: by the announcement engine while ringing and after the
    /// call, and by VoiceOver while connecting and connected.
    var statusText: String {
        switch state {
        case .idle, .ringing: progressText
        case .connecting: "Connecting to \(volunteerName ?? "a volunteer")"
        case .connected: "Connected to \(volunteerName ?? "a volunteer")"
        case .ended(.hungUp): "Call ended"
        case .ended(.declined): "\(volunteerName ?? "The volunteer") declined the call"
        case .ended(.unanswered): "Nobody answered"
        case .ended(.remoteLeft): "\(volunteerName ?? "The volunteer") left the call"
        case .failed(let message): message
        }
    }

    func start() async {
        placing = Task { await placeCall() }
        for await state in services.videoCall.states() {
            await receive(state)
        }
    }

    /// Every failure, and the end of a call, offers this.
    func retry() {
        placing?.cancel()
        placing = Task { await placeCall() }
    }

    func hangUp() async {
        placing?.cancel()
        guard state.isActive else { return }
        await services.videoCall.disconnect()
        if let ticket { await services.callSignaling.endCall(callID: ticket.callID) }
        if state.isActive { state = .ended(.hungUp) }
        await services.announcements.setInCall(false)
        await say("Call ended.", haptic: nil)
    }

    func toggleMute() async {
        controlError = nil
        do {
            try await services.videoCall.setMicrophoneMuted(!isMuted)
            isMuted.toggle()
        } catch {
            controlError = "Couldn't change the microphone."
        }
    }

    func flipCamera() async {
        controlError = nil
        do {
            try await services.videoCall.flipCamera()
            isUsingBackCamera.toggle()
            // Only the back camera has a light, and flipping turns it off.
            if !isUsingBackCamera { isFlashlightOn = false }
        } catch {
            controlError = "Couldn't switch cameras."
        }
    }

    func toggleFlashlight() async {
        controlError = nil
        guard isUsingBackCamera else {
            controlError = "The flashlight only works with the back camera."
            return
        }
        do {
            try await services.videoCall.setFlashlight(!isFlashlightOn)
            isFlashlightOn.toggle()
        } catch {
            controlError = "Couldn't turn the flashlight \(isFlashlightOn ? "off" : "on")."
        }
    }

    // MARK: - Placing the call

    private func placeCall() async {
        failure = nil
        ticket = nil
        volunteerName = nil
        hasStartedConnecting = false
        isMuted = false
        isUsingBackCamera = true
        isFlashlightOn = false
        progressText = "Calling a volunteer"
        state = .ringing

        // Checked before ringing anyone, so a volunteer is never left waiting for a call that can't connect.
        if let missing = await missingPermission() {
            await fail(missing)
            return
        }
        await say("Calling a volunteer. This can take a minute.", haptic: .attention)

        do {
            // Rings the picked volunteer first, then others, 30 seconds each, until one accepts.
            let ticket = try await services.callSignaling.requestCall(preferring: preferred?.id) { [weak self] progress in
                Task { @MainActor in await self?.receive(progress) }
            }
            self.ticket = ticket
            if ticket.volunteerID == preferred?.id { volunteerName = preferred?.name }
            hasStartedConnecting = true
            try await services.videoCall.connect(with: ticket)
        } catch {
            // Hanging up or leaving the screen cancels the call; that isn't a failure.
            guard !Task.isCancelled else { return }
            await fail(Self.failure(for: error, connecting: hasStartedConnecting))
        }
    }

    private func receive(_ progress: CallRequestProgress) async {
        guard state == .ringing else { return }
        switch progress {
        case .ringing:
            // "Calling a volunteer" was said when the call started; each next one follows a .tryingNext.
            break
        case .tryingNext(after: .noAnswer):
            progressText = "No answer. Trying another volunteer."
            await say(progressText, haptic: .attention)
        case .tryingNext(after: .declined):
            progressText = "That volunteer couldn't take the call. Trying another volunteer."
            await say(progressText, haptic: .attention)
        }
    }

    private func receive(_ newState: CallState) async {
        guard hasStartedConnecting else { return }
        state = newState
        // From connecting on, only turn cues and critical alerts are spoken (VOLUNTEER-5).
        await services.announcements.setInCall(newState.isActive)
        if newState == .connected {
            await services.haptics.play(.arrived, intensity: 1)
        }
        guard !newState.isActive else { return }
        // The other person left or the connection dropped: mark the call ended so the
        // volunteer is free for the next caller.
        if let ticket { await services.callSignaling.endCall(callID: ticket.callID) }
        switch newState {
        case .failed:
            await fail(.connectionFailed)
        case .ended(.hungUp):
            break // hangUp() already said it
        default:
            await say(statusText, haptic: .attention)
        }
    }

    private func fail(_ failure: CallFailure) async {
        self.failure = failure
        state = .failed(failure.message)
        await services.announcements.setInCall(false)
        // Spoken with the way out, so it works without looking at the screen.
        await say("\(failure.message) \(failure.spokenNextStep)", haptic: .error)
    }

    /// Spoken through the announcement engine, so it works with or without VoiceOver and plays
    /// the haptic at the user's chosen strength.
    private func say(_ text: String, haptic: HapticID?) async {
        await services.announcements.submit(AnnouncementEvent(
            category: .system, priority: .high, text: text, haptic: haptic, source: .userInteraction
        ))
    }

    /// The caller sends their camera and voice, so both permissions are needed.
    private func missingPermission() async -> CallFailure? {
        // Previews and tests use the placeholder call, which needs neither.
        guard !(services.videoCall is PlaceholderVideoCallSession) else { return nil }
        for (type, name) in [(AVMediaType.audio, "microphone"), (AVMediaType.video, "camera")] {
            switch AVCaptureDevice.authorizationStatus(for: type) {
            case .authorized:
                continue
            case .notDetermined:
                if await AVCaptureDevice.requestAccess(for: type) { continue }
                return .permissionDenied(name)
            default:
                return .permissionDenied(name)
            }
        }
        return nil
    }

    private static func failure(for error: Error, connecting: Bool) -> CallFailure {
        if let error = error as? CallSignalingError {
            switch error {
            case .noVolunteers: return .noVolunteers
            case .nobodyAnswered: return .nobodyAnswered
            case .offline: return .offline
            default: break
            }
        }
        if case .permissionDenied(let name)? = error as? CallSessionError {
            return .permissionDenied(name.lowercased())
        }
        if connecting { return .connectionFailed }
        return .other((error as? LocalizedError)?.errorDescription ?? "Something went wrong.")
    }
}

/// Every way a call can fail. Each has a spoken message and a retry; permissions also offer Settings.
enum CallFailure: Equatable, Sendable {
    case noVolunteers
    /// Everyone rung declined or didn't answer.
    case nobodyAnswered
    case offline
    /// "camera" or "microphone".
    case permissionDenied(String)
    /// The volunteer answered but the video call couldn't connect, or it dropped.
    case connectionFailed
    case other(String)

    var message: String {
        switch self {
        case .noVolunteers: "No volunteers are online right now."
        case .nobodyAnswered: "No volunteer could take the call right now."
        case .offline: "You're offline. Check your internet connection."
        case .permissionDenied(let name): "AccessAble needs your \(name) for calls, and access is turned off."
        case .connectionFailed: "The call couldn't connect. It may be a weak connection."
        case .other(let message): message
        }
    }

    var spokenNextStep: String {
        switch self {
        case .permissionDenied: "Use Open Settings to turn it on, then Try again."
        default: "Use Try again to call again."
        }
    }

    var needsSettings: Bool {
        if case .permissionDenied = self { true } else { false }
    }
}
