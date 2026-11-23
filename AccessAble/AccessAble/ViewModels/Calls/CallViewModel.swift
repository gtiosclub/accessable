import Foundation
import Observation

/// Owner: Calls (VOLUNTEER-5). One call, from asking for a ticket to hanging up.
@MainActor
@Observable
final class CallViewModel {
    let partnerName: String
    private(set) var state: CallState = .idle
    private(set) var isMuted = false
    private(set) var isUsingBackCamera = true
    private(set) var isFlashlightOn = false
    private(set) var controlError: String?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let partnerID: String
    @ObservationIgnored private var ticket: CallTicket?
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
        case .idle, .ringing: "Calling \(partnerName)"
        case .connecting: "Connecting"
        case .connected: "Connected to \(partnerName)"
        case .ended(.hungUp): "Call ended"
        case .ended(.declined): "\(partnerName) declined the call"
        case .ended(.unanswered): "\(partnerName) didn't answer"
        case .ended(.remoteLeft): "\(partnerName) left the call"
        case .failed(let message): "Call failed. \(message)"
        }
    }

    func start() async {
        await withDiscardingTaskGroup { group in
            group.addTask { [services] in
                for await state in services.videoCall.states() {
                    await self.receive(state)
                }
            }
            group.addTask { await self.placeCall() }
        }
    }

    func hangUp() async {
        guard state.isActive else { return }
        await services.videoCall.disconnect()
        if let ticket { await services.callSignaling.end(ticket) }
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
            let ticket = try await services.callSignaling.startCall(to: partnerID)
            self.ticket = ticket
            hasStartedConnecting = true
            try await services.videoCall.connect(with: ticket)
        } catch {
            // Leaving the screen cancels the call; that isn't a failure.
            guard !Task.isCancelled else { return }
            if state.isActive { state = .failed("Check your connection and try again.") }
            await services.announcements.setInCall(false)
        }
    }

    private func receive(_ newState: CallState) async {
        guard hasStartedConnecting else { return }
        state = newState
        await services.announcements.setInCall(newState.isActive)
    }
}
