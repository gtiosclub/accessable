import Foundation
import Observation

/// One foreground volunteer host owns the listener, ring deadline, and accepted session.
@MainActor
@Observable
final class IncomingCallViewModel {
    enum Phase: Equatable { case idle, ringing, accepting, connecting, connected, ending }
    private(set) var call: IncomingCall?
    private(set) var phase: Phase = .idle
    private(set) var message: String?
    private(set) var listenerError: String?
    private(set) var isMuted = false
    private(set) var listenerAttempt = 0

    @ObservationIgnored private let volunteerID: String
    @ObservationIgnored private let source: any IncomingCallProviding
    @ObservationIgnored private let signaling: any CallSignaling
    @ObservationIgnored private let video: any VideoCallSession
    @ObservationIgnored private let announcements: any AnnouncementEngineProtocol
    @ObservationIgnored private let alerts: any IncomingCallAlerting
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var endingTask: Task<Void, Never>?
    @ObservationIgnored private var listenerGeneration = UUID()
    @ObservationIgnored private var actionGeneration = UUID()
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var latestOffer: IncomingCall?
    @ObservationIgnored private var dismissedIDs: Set<String> = []

    init(volunteerID: String, source: any IncomingCallProviding, signaling: any CallSignaling,
         video: any VideoCallSession, announcements: any AnnouncementEngineProtocol,
         alerts: any IncomingCallAlerting, now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.volunteerID = volunteerID
        self.source = source
        self.signaling = signaling
        self.video = video
        self.announcements = announcements
        self.alerts = alerts
        self.now = now
        self.sleep = sleep
    }

    func listen() async {
        let generation = UUID()
        listenerGeneration = generation
        foreground = true
        listenerError = nil
        defer {
            if listenerGeneration == generation { suspendListening() }
        }
        do {
            for try await offer in source.incomingCalls(volunteerID: volunteerID) {
                guard !Task.isCancelled, listenerGeneration == generation else { return }
                latestOffer = offer
                if phase == .ringing, offer?.id != call?.id {
                    if let call { dismissedIDs.insert(call.id) }
                    dismissRing()
                }
                presentLatestIfPossible()
            }
        } catch {
            guard !Task.isCancelled, listenerGeneration == generation else { return }
            let text = "Couldn't listen for incoming calls. Check your connection and try again."
            listenerError = text
            alerts.announce(text)
        }
    }

    func suspendListening() {
        listenerGeneration = UUID()
        foreground = false
        latestOffer = nil
        if phase == .ringing { dismissRing() }
    }

    func retryListening() { listenerAttempt += 1 }
    func dismissMessage() { message = nil }

    private func presentLatestIfPossible() {
        guard foreground, phase == .idle, let offer = latestOffer,
              !dismissedIDs.contains(offer.id) else { return }
        let remaining = offer.remainingTime(at: now())
        guard remaining > 0 else { dismissedIDs.insert(offer.id); return }
        message = nil
        call = offer
        phase = .ringing
        isMuted = false
        alerts.start()
        deadlineTask = Task { [weak self, sleep] in
            do { try await sleep(.seconds(remaining)) }
            catch { return }
            guard !Task.isCancelled, let self,
                  phase == .ringing, call?.id == offer.id else { return }
            dismissedIDs.insert(offer.id)
            dismissRing()
            // UI timeout only. MATCH's stale-ring rule frees the volunteer at 45 seconds.
        }
    }

    /// Called after the incoming screen has appeared so its presentation doesn't swallow speech.
    func announceIncomingCall() {
        guard phase == .ringing, let call else { return }
        alerts.announce("Incoming call from \(call.callerFirstName)")
    }

    func accept() {
        guard phase == .ringing, let call else { return }
        guard call.remainingTime(at: now()) > 0 else {
            dismissedIDs.insert(call.id)
            dismissRing()
            report("This call was taken or ended.")
            return
        }
        dismissedIDs.insert(call.id)
        stopRinging()
        phase = .accepting
        let generation = UUID()
        actionGeneration = generation
        actionTask = Task { [weak self] in
            guard let self else { return }
            await performAccept(call, generation: generation)
        }
    }

    private func performAccept(_ offer: IncomingCall, generation: UUID) async {
        var joining = false
        do {
            let ticket = try await signaling.accept(callID: offer.id)
            try Task.checkCancellation()
            guard generation == actionGeneration else { return }
            guard ticket.callID == offer.id, ticket.volunteerID == volunteerID,
                  !ticket.isExpired(at: now()) else { throw CallSignalingError.callTaken }
            phase = .connecting
            joining = true
            await announcements.setInCall(true)
            try Task.checkCancellation()
            try await video.connect(with: ticket)
            try Task.checkCancellation()
            guard generation == actionGeneration else { return }
            phase = .connected
            alerts.announce("Connected to \(offer.callerFirstName)")
            sessionTask = Task { [weak self, video] in
                // Subscribe after this connect, so a replayed end from a previous call is ignored.
                for await state in video.states() {
                    guard !Task.isCancelled, let self, generation == actionGeneration else { return }
                    switch state {
                    case .ended, .failed:
                        endCall()
                        return
                    default: break
                    }
                }
            }
        } catch {
            guard !Task.isCancelled, generation == actionGeneration else { return }
            call = nil
            phase = .ending
            report(joining ? "Couldn't connect the call. Check your microphone permission and connection."
                           : "This call was taken or ended.")
            // Accept can have committed even if the Worker/token request failed afterward.
            // End that same call to avoid stranding the volunteer inCall.
            await video.disconnect()
            await signaling.endCall(callID: offer.id)
            await announcements.setInCall(false)
            guard generation == actionGeneration else { return }
            phase = .idle
            presentLatestIfPossible()
        }
    }

    func decline() {
        guard phase == .ringing, let call else { return }
        dismissedIDs.insert(call.id)
        dismissRing()
        Task { [weak self, signaling] in
            do { try await signaling.decline(callID: call.id) }
            catch { self?.report("Couldn't send the decline. The ring will expire automatically.") }
        }
    }

    func endCall() {
        guard let call, phase != .idle, phase != .ending else { return }
        stopRinging()
        dismissedIDs.insert(call.id)
        phase = .ending
        actionGeneration = UUID()
        let pending = actionTask
        pending?.cancel()
        sessionTask?.cancel()
        sessionTask = nil
        endingTask = Task { [weak self, video, signaling, announcements] in
            await pending?.value
            await video.disconnect()
            await signaling.endCall(callID: call.id)
            await announcements.setInCall(false)
            guard let self else { return }
            self.call = nil
            phase = .idle
            alerts.announce("Call ended")
            actionTask = nil
            endingTask = nil
            presentLatestIfPossible()
        }
    }

    func toggleMute() async {
        guard phase == .connected else { return }
        do { try await video.setMicrophoneMuted(!isMuted); isMuted.toggle() }
        catch { report("Couldn't change the microphone.") }
    }

    /// Root volunteer host disappeared (for example sign-out), not just a navigation push.
    func shutdown() {
        suspendListening()
        if phase != .idle { endCall() }
        alerts.stop()
    }

    private func stopRinging() {
        deadlineTask?.cancel()
        deadlineTask = nil
        alerts.stop()
    }

    private func dismissRing() {
        stopRinging()
        call = nil
        phase = .idle
    }

    private func report(_ text: String) { message = text; alerts.announce(text) }
}
