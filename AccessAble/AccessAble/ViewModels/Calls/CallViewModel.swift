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
    /// Whether the volunteer can see this phone's camera.
    private(set) var isCameraOn = true
    private(set) var controlError: String?
    private(set) var isUpdatingControls = false
    /// The volunteer who answered, once known. Nil while ringing, or if it isn't the one picked.
    private(set) var volunteerName: String?
    private(set) var lastCallForSafety: CallSafetySummary?

    @ObservationIgnored private let services: AppServices
    /// The volunteer the caller picked, rung first. Nil for "Call a volunteer".
    @ObservationIgnored private let preferred: Volunteer?
    @ObservationIgnored private var ticket: CallTicket?
    /// Ringing volunteers one at a time; cancelled when the caller hangs up or leaves the screen.
    @ObservationIgnored private var placing: Task<Void, Never>?
    @ObservationIgnored private var observing: Task<Void, Never>?
    @ObservationIgnored private var attemptGeneration = UUID()
    /// The session replays its last state, which may be the end of an earlier call;
    /// states are only taken once this call has started connecting.
    @ObservationIgnored private var hasStartedConnecting = false
    @ObservationIgnored private var isFinishing = false
    @ObservationIgnored private let permissionCheck: (@MainActor () async -> CallFailure?)?
    /// A volunteer's ring the caller is answering (CALLBACK-1), instead of ringing volunteers.
    @ObservationIgnored private let answering: VolunteerRing?

    init(services: AppServices, volunteer: Volunteer?, answering: VolunteerRing? = nil,
         permissionCheck: (@MainActor () async -> CallFailure?)? = nil) {
        self.services = services
        self.preferred = volunteer
        self.answering = answering
        self.permissionCheck = permissionCheck
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
        guard state == .idle else { return }
        placing = Task { await placeCall() }
        await placing?.value
    }

    /// Every failure, and the end of a call, offers this.
    func retry() {
        guard !state.isActive, !isFinishing else { return }
        attemptGeneration = UUID()
        observing?.cancel()
        observing = nil
        hasStartedConnecting = false
        let previous = placing
        previous?.cancel()
        state = .ringing
        placing = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await services.videoCall.disconnect()
            guard !Task.isCancelled else { return }
            await placeCall()
        }
    }

    func hangUp() async {
        guard !isFinishing else { return }
        let pending = placing
        pending?.cancel()
        guard state.isActive || ticket != nil else { return }
        isFinishing = true
        defer { isFinishing = false }
        attemptGeneration = UUID()
        observing?.cancel()
        observing = nil
        hasStartedConnecting = false
        // A late token/connect result must finish before another attempt can use the session.
        await pending?.value
        await services.videoCall.disconnect()
        if let ticket { await services.callSignaling.endCall(callID: ticket.callID) }
        ticket = nil
        state = .ended(.hungUp)
        await services.announcements.setInCall(false)
        await say("Call ended.", haptic: nil)
    }

    func toggleMute() async {
        guard state == .connected, !isUpdatingControls else { return }
        isUpdatingControls = true
        defer { isUpdatingControls = false }
        controlError = nil
        let generation = attemptGeneration
        do {
            try await services.videoCall.setMicrophoneMuted(!isMuted)
            guard generation == attemptGeneration, state == .connected else { return }
            isMuted.toggle()
        } catch {
            guard generation == attemptGeneration, state == .connected else { return }
            controlError = "Couldn't change the microphone."
        }
    }

    func flipCamera() async {
        guard state == .connected, !isUpdatingControls else { return }
        isUpdatingControls = true
        defer { isUpdatingControls = false }
        controlError = nil
        let generation = attemptGeneration
        // The session turns the light off before switching, even if the switch then fails.
        isFlashlightOn = false
        do {
            try await services.videoCall.flipCamera()
            guard generation == attemptGeneration, state == .connected else { return }
            isUsingBackCamera.toggle()
        } catch {
            guard generation == attemptGeneration, state == .connected else { return }
            controlError = "Couldn't switch cameras."
        }
    }

    func toggleCamera() async {
        guard state == .connected, !isUpdatingControls else { return }
        isUpdatingControls = true
        defer { isUpdatingControls = false }
        controlError = nil
        do {
            try await services.videoCall.setCameraEnabled(!isCameraOn)
            isCameraOn.toggle()
            if !isCameraOn { isFlashlightOn = false }
        } catch {
            controlError = "Couldn't turn the camera \(isCameraOn ? "off" : "on")."
        }
    }

    func toggleFlashlight() async {
        guard state == .connected, !isUpdatingControls else { return }
        isUpdatingControls = true
        defer { isUpdatingControls = false }
        controlError = nil
        let generation = attemptGeneration
        guard isUsingBackCamera else {
            controlError = "The flashlight only works with the back camera."
            return
        }
        do {
            try await services.videoCall.setFlashlight(!isFlashlightOn)
            guard generation == attemptGeneration, state == .connected else { return }
            isFlashlightOn.toggle()
        } catch {
            guard generation == attemptGeneration, state == .connected else { return }
            controlError = "Couldn't turn the flashlight \(isFlashlightOn ? "off" : "on")."
        }
    }

    // MARK: - Placing the call

    private func placeCall() async {
        lastCallForSafety = nil
        let generation = UUID()
        attemptGeneration = generation
        failure = nil
        ticket = nil
        volunteerName = nil
        hasStartedConnecting = false
        isMuted = false
        isUsingBackCamera = true
        isFlashlightOn = false
        isCameraOn = true
        progressText = "Calling a volunteer"
        state = .ringing

        // Checked before ringing anyone, so a volunteer is never left waiting for a call that can't connect.
        let missing = await missingPermission()
        guard !Task.isCancelled else { return }
        if let missing {
            await fail(missing)
            return
        }
        if answering == nil { await say("Calling a volunteer. This can take a minute.", haptic: .attention) }

        do {
            // Rings the picked volunteer first, then others, 30 seconds each, until one accepts.
            try Task.checkCancellation()
            let ticket: CallTicket
            if let answering {
                ticket = try await services.callSignaling.answerVolunteerRing(callID: answering.id)
            } else {
                ticket = try await services.callSignaling.requestCall(preferring: preferred?.id) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.attemptGeneration == generation else { return }
                        await self.receive(progress)
                    }
                }
            }
            self.ticket = ticket
            lastCallForSafety = CallSafetySummary(id: ticket.callID, otherUserID: ticket.volunteerID, canBlockVolunteer: true)
            try Task.checkCancellation()
            if ticket.volunteerID == preferred?.id { volunteerName = preferred?.name }
            hasStartedConnecting = true
            state = .connecting
            await services.announcements.setInCall(true)
            try Task.checkCancellation()
            try await services.videoCall.connect(with: ticket)
            try Task.checkCancellation()
            try Task.checkCancellation()
            // Subscribe only after this join, with a generation fence. An old session's
            // replayed/queued terminal state must not end a subsequent call.
            let video = services.videoCall
            observing = Task { [weak self] in
                for await state in video.states() {
                    guard !Task.isCancelled, let self, attemptGeneration == generation else { return }
                    await receive(state, generation: generation)
                    guard hasStartedConnecting, attemptGeneration == generation else { return }
                }
            }
        } catch {
            let connecting = hasStartedConnecting
            hasStartedConnecting = false
            observing?.cancel()
            observing = nil
            await services.videoCall.disconnect()
            if let ticket { await services.callSignaling.endCall(callID: ticket.callID) }
            ticket = nil
            // Hanging up or leaving the screen cancels the call; that isn't a failure.
            guard !Task.isCancelled else { return }
            await fail(Self.failure(for: error, connecting: connecting))
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

    private func receive(_ newState: CallState, generation: UUID) async {
        guard hasStartedConnecting, attemptGeneration == generation, !Task.isCancelled else { return }
        if newState.isActive {
            state = newState
            await services.announcements.setInCall(true)
            if newState == .connected, hasStartedConnecting, attemptGeneration == generation {
                await services.haptics.play(.arrived, intensity: 1)
            }
            return
        }
        // A failed connect is cleaned up by placeCall first. Do not expose Retry early.
        await placing?.value
        guard hasStartedConnecting, !isFinishing, attemptGeneration == generation, !Task.isCancelled else { return }
        isFinishing = true
        hasStartedConnecting = false
        // Let this observer finish cleanup without cancelling its Firestore operation.
        observing = nil
        if let ticket { await services.callSignaling.endCall(callID: ticket.callID) }
        ticket = nil
        await services.announcements.setInCall(false)
        isFinishing = false
        // Set terminal UI only after cleanup. A new attempt can no longer race old writes.
        if case .failed = newState {
            await fail(.connectionFailed)
            return
        }
        state = newState
        if newState != .ended(.hungUp) { await say(statusText, haptic: .attention) }
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
            category: .system, priority: .high, text: text, haptic: haptic, source: .userInteraction,
            isCallAnnouncement: true
        ))
    }

    /// The caller sends their camera and voice, so both permissions are needed.
    private func missingPermission() async -> CallFailure? {
        if let permissionCheck { return await permissionCheck() }
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
