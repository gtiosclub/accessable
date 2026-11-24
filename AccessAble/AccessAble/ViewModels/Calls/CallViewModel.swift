import Foundation
import Observation

/// Owner: Calls (VOLUNTEER-5, matching from VOLUNTEER-6). One call, from ringing volunteers to hanging up.
@MainActor
@Observable
final class CallViewModel {
    /// Who answered. Starts as the volunteer the caller picked; another volunteer may answer instead.
    private(set) var partnerName: String
    private(set) var state: CallState = .idle
    private(set) var isMuted = false
    private(set) var isUsingBackCamera = true
    private(set) var isFlashlightOn = false
    private(set) var controlError: String?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let partnerID: String
    @ObservationIgnored private var ticket: CallTicket?
    /// Ringing volunteers one at a time; cancelled when the caller hangs up or leaves the screen.
    @ObservationIgnored private var placing: Task<Void, Never>?
    /// The session replays its last state, which may be the end of an earlier call;
    /// states are only taken once this call has started connecting.
    @ObservationIgnored private var hasStartedConnecting = false

    init(services: AppServices, partnerID: String, partnerName: String) {
        self.services = services
        self.partnerID = partnerID
        self.partnerName = partnerName
    }

    /// What VoiceOver announces on every change, and what the screen shows.
    var statusText: String {
        switch state {
        case .idle, .ringing: "Calling a volunteer"
        case .connecting: "Connecting"
        case .connected: "Connected to \(partnerName)"
        case .ended(.hungUp): "Call ended"
        case .ended(.declined): "\(partnerName) declined the call"
        case .ended(.unanswered): "Nobody answered"
        case .ended(.remoteLeft): "\(partnerName) left the call"
        case .failed(let message): "Call failed. \(message)"
        }
    }

    func start() async {
        placing = Task { await placeCall() }
        for await state in services.videoCall.states() {
            await receive(state)
        }
    }

    func hangUp() async {
        placing?.cancel()
        guard state.isActive else { return }
        await services.videoCall.disconnect()
        if let ticket { await services.callSignaling.endCall(callID: ticket.callID) }
        if state.isActive { state = .ended(.hungUp) }
        await services.announcements.setInCall(false)
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

    // MARK: - Private

    private func placeCall() async {
        state = .ringing
        await services.announcements.setInCall(true)
        do {
            // Rings the picked volunteer first, then others, 30 seconds each, until one accepts.
            let ticket = try await services.callSignaling.requestCall(preferring: partnerID)
            self.ticket = ticket
            if ticket.volunteerID != partnerID { partnerName = "a volunteer" }
            hasStartedConnecting = true
            try await services.videoCall.connect(with: ticket)
        } catch {
            // Hanging up or leaving the screen cancels the call; that isn't a failure.
            guard !Task.isCancelled else { return }
            if state.isActive {
                state = .failed((error as? LocalizedError)?.errorDescription ?? "Check your connection and try again.")
            }
            await services.announcements.setInCall(false)
        }
    }

    private func receive(_ newState: CallState) async {
        guard hasStartedConnecting else { return }
        state = newState
        await services.announcements.setInCall(newState.isActive)
        // The other person left or the connection dropped: mark the call ended so the
        // volunteer is free for the next caller.
        if !newState.isActive, let ticket {
            await services.callSignaling.endCall(callID: ticket.callID)
        }
    }
}
