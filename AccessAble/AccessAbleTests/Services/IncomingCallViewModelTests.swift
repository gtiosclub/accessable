import Foundation
import Testing
@testable import AccessAble

@MainActor
struct IncomingCallViewModelTests {
    @Test func incomingNameAlertsOnceAndDuplicateSnapshotsDoNotRestartRinging() async throws {
        let h = IncomingHarness()
        defer { h.stop() }
        try await h.ready()
        h.source.send(h.offer())
        try await waitFor { h.model.phase == .ringing }
        h.model.announceIncomingCall()
        h.source.send(h.offer())
        await Task.yield()
        #expect(h.alerts.starts == 1)
        #expect(h.alerts.spoken == ["Incoming call from Alex"])
        #expect(h.model.call?.callerFirstName == "Alex")
    }

    @Test func declineUsesTransactionAndStopsAlertsImmediately() async throws {
        let h = IncomingHarness()
        defer { h.stop() }
        try await h.ready()
        h.source.send(h.offer())
        try await waitFor { h.model.phase == .ringing }
        h.model.decline()
        #expect(h.model.call == nil)
        #expect(!h.alerts.ringing)
        try await waitFor { h.signaling.declines == ["ring-1"] }
        h.source.send(h.offer())
        await Task.yield()
        #expect(h.model.call == nil)
    }

    @Test func deadlineDismissesWithoutMutatingBackendOrReplayingSameRing() async throws {
        let sleeper = RingSleepRecorder()
        let h = IncomingHarness(sleep: { try await sleeper.sleep($0) })
        defer { h.stop() }
        try await h.ready()
        h.source.send(h.offer())
        try await waitFor { h.model.phase == .ringing }
        try await waitFor { h.model.call == nil }
        #expect(!h.alerts.ringing)
        #expect(h.signaling.declines.isEmpty && h.signaling.ends.isEmpty)
        let durations = await sleeper.durations
        #expect(durations == [.seconds(30)])
        h.source.send(h.offer())
        await Task.yield()
        #expect(h.alerts.starts == 1)
    }

    @Test func withdrawnCallDismissesAndOldOffersNeverRing() async throws {
        let h = IncomingHarness()
        defer { h.stop() }
        try await h.ready()
        h.source.send(h.offer(since: h.time.addingTimeInterval(-31)))
        await Task.yield()
        #expect(h.model.call == nil)
        h.source.send(h.offer(id: "fresh"))
        try await waitFor { h.model.phase == .ringing }
        h.source.send(nil)
        try await waitFor { h.model.call == nil }
        #expect(!h.alerts.ringing)
    }

    @Test func acceptJoinsExactlyOnceWithReturnedTicket() async throws {
        let h = IncomingHarness()
        defer { h.stop() }
        try await h.ready()
        h.source.send(h.offer())
        try await waitFor { h.model.phase == .ringing }
        h.model.accept()
        h.model.accept()
        try await waitFor { h.model.phase == .connected }
        #expect(h.signaling.accepts == ["ring-1"])
        #expect(h.video.connections.map(\.callID) == ["ring-1"])
        #expect(!h.alerts.ringing)
        h.model.endCall()
        try await waitFor { h.model.phase == .idle }
        #expect(h.signaling.ends == ["ring-1"])
        #expect(h.video.disconnects == 1)
    }

    @Test func failedAcceptSpeaksRequiredMessageAndNeverJoins() async throws {
        let h = IncomingHarness()
        defer { h.stop() }
        h.signaling.mode = .taken
        try await h.ready()
        h.source.send(h.offer())
        try await waitFor { h.model.phase == .ringing }
        h.model.accept()
        try await waitFor { h.model.phase == .idle && h.model.message != nil }
        #expect(h.model.message == "This call was taken or ended.")
        #expect(h.alerts.spoken.contains("This call was taken or ended."))
        #expect(h.video.connections.isEmpty)
        #expect(h.model.call == nil)
        #expect(h.signaling.ends == ["ring-1"])
    }

    @Test func clearingRingingIDDuringAcceptDoesNotDismissTheAnswer() async throws {
        let h = IncomingHarness()
        defer { h.stop() }
        h.signaling.mode = .waiting
        try await h.ready()
        h.source.send(h.offer())
        try await waitFor { h.model.phase == .ringing }
        h.model.accept()
        try await waitFor { h.signaling.pending != nil }
        h.source.send(nil) // The accept transaction clears ringingCallId before fetching a token.
        await Task.yield()
        #expect(h.model.phase == .accepting)
        #expect(h.model.call?.id == "ring-1")
        h.signaling.resolve()
        try await waitFor { h.model.phase == .connected }
    }

    @Test func endingAnInFlightAcceptCannotConnectLater() async throws {
        let h = IncomingHarness()
        defer { h.stop() }
        h.signaling.mode = .waiting
        try await h.ready()
        h.source.send(h.offer())
        try await waitFor { h.model.phase == .ringing }
        h.model.accept()
        try await waitFor { h.signaling.pending != nil }
        h.model.endCall()
        h.signaling.resolve()
        try await waitFor { h.model.phase == .idle }
        #expect(h.video.connections.isEmpty)
        #expect(h.signaling.ends == ["ring-1"])
    }

    @Test func connectionFailureReleasesAcceptedCall() async throws {
        let h = IncomingHarness()
        defer { h.stop() }
        h.video.shouldFail = true
        try await h.ready()
        h.source.send(h.offer())
        try await waitFor { h.model.phase == .ringing }
        h.model.accept()
        try await waitFor { h.model.phase == .idle && h.model.message != nil }
        #expect(h.signaling.ends == ["ring-1"])
        #expect(h.model.call == nil)
        #expect(h.model.message?.contains("Couldn't connect") == true)
    }

    @Test func listenerFailureIsVisibleAndCancellingStopsTheRing() async throws {
        let h = IncomingHarness()
        defer { h.stop() }
        try await h.ready()
        h.source.send(h.offer())
        try await waitFor { h.model.phase == .ringing }
        h.source.fail()
        try await waitFor { h.model.listenerError != nil }
        #expect(h.model.call == nil)
        #expect(!h.alerts.ringing)
        h.model.retryListening()
        #expect(h.model.listenerAttempt == 1)
    }

    @Test func backgroundStopsRingingWithoutDeclining() async throws {
        let h = IncomingHarness()
        defer { h.stop() }
        try await h.ready()
        h.source.send(h.offer())
        try await waitFor { h.model.phase == .ringing }
        h.task?.cancel()
        h.model.suspendListening()
        #expect(h.model.call == nil)
        #expect(!h.alerts.ringing)
        #expect(h.signaling.declines.isEmpty)
    }

    @Test func firstNameAndDeadlineNormalization() {
        #expect(IncomingCall.firstName(from: " \tAlex Rivera") == "Alex")
        #expect(IncomingCall.firstName(from: "김 예은") == "김")
        #expect(IncomingCall.firstName(from: "   ") == "Caller")
        // The rules split on RE2's \\s, which has no vertical tab, so neither may the app.
        #expect(IncomingCall.firstName(from: "Sam\u{000B}Lee Kim") == "Sam\u{000B}Lee")
        let now = Date()
        let late = IncomingCall(id: "a", callerFirstName: "Alex", ringingSince: now.addingTimeInterval(-20))
        #expect(late.remainingTime(at: now) == 10)
        let future = IncomingCall(id: "b", callerFirstName: "Alex", ringingSince: now.addingTimeInterval(100))
        #expect(future.remainingTime(at: now) == 30)
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw IncomingTestError.timeout
    }
}

private enum IncomingTestError: Error { case timeout, failed }

@MainActor
private final class IncomingHarness {
    let source: TestIncomingSource
    let signaling: TestIncomingSignaling
    let video: TestIncomingVideo
    let alerts: TestIncomingAlerts
    let model: IncomingCallViewModel
    let time: Date
    var task: Task<Void, Never>?

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        let source = TestIncomingSource(), signaling = TestIncomingSignaling()
        let video = TestIncomingVideo(), alerts = TestIncomingAlerts()
        let time = Date()
        self.source = source; self.signaling = signaling; self.video = video; self.alerts = alerts; self.time = time
        model = IncomingCallViewModel(volunteerID: "helper", source: source, signaling: signaling,
                                     video: video, announcements: PlaceholderAnnouncementEngine(), alerts: alerts,
                                     now: { time }, sleep: sleep)
    }

    func ready() async throws {
        task = Task { await model.listen() }
        for _ in 0..<200 {
            if source.continuation != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw IncomingTestError.timeout
    }

    func offer(id: String = "ring-1", since: Date? = nil) -> IncomingCall {
        IncomingCall(id: id, callerFirstName: "Alex", ringingSince: since ?? time)
    }

    func stop() {
        task?.cancel()
        source.continuation?.finish()
        model.shutdown()
        signaling.resolve() // Release a suspended test accept even if an assertion timed out.
    }
}

@MainActor
private final class TestIncomingSource: IncomingCallProviding {
    var continuation: AsyncThrowingStream<IncomingCall?, Error>.Continuation?
    func incomingCalls(volunteerID: String) -> AsyncThrowingStream<IncomingCall?, Error> {
        let pair = AsyncThrowingStream<IncomingCall?, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func send(_ call: IncomingCall?) { continuation?.yield(call) }
    func fail() { continuation?.finish(throwing: IncomingTestError.failed) }
}

@MainActor
private final class TestIncomingAlerts: IncomingCallAlerting {
    var starts = 0
    var ringing = false
    var spoken: [String] = []
    func start() { starts += 1; ringing = true }
    func stop() { ringing = false }
    func announce(_ text: String) { spoken.append(text) }
}

@MainActor
private final class TestIncomingSignaling: CallSignaling {
    enum Mode { case success, taken, waiting }
    var mode: Mode = .success
    var accepts: [String] = [], declines: [String] = [], ends: [String] = []
    var pending: CheckedContinuation<CallTicket, Error>?
    private var pendingID = ""
    @MainActor func requestCall(preferring volunteerID: String?, progress: @Sendable (CallRequestProgress) -> Void) async throws -> CallTicket {
        throw IncomingTestError.failed
    }
    @MainActor func accept(callID: String) async throws -> CallTicket {
        accepts.append(callID)
        switch mode {
        case .taken: throw CallSignalingError.callTaken
        case .success: return ticket(callID)
        case .waiting:
            pendingID = callID
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
    }
    func resolve() { pending?.resume(returning: ticket(pendingID)); pending = nil }
    @MainActor func decline(callID: String) async throws { declines.append(callID) }
    @MainActor func skip(callID: String) async throws {}
    @MainActor func endCall(callID: String) async { ends.append(callID) }
    private func ticket(_ id: String) -> CallTicket {
        CallTicket(callID: id, roomName: "call-\(id)", token: "fake", callerID: "caller",
                   volunteerID: "helper", expiresAt: .now.addingTimeInterval(60))
    }
}

@MainActor
private final class TestIncomingVideo: VideoCallSession {
    private nonisolated let events = Broadcaster<CallState>(replaysLatest: true)
    var connections: [CallTicket] = []
    var disconnects = 0
    var shouldFail = false
    init() { events.send(.ended(.hungUp)) } // A stale previous session must not end this call.
    nonisolated func states() -> AsyncStream<CallState> { events.stream() }
    @MainActor func connect(with ticket: CallTicket) async throws {
        connections.append(ticket)
        if shouldFail { throw IncomingTestError.failed }
        events.send(.connecting)
        events.send(.connected)
    }
    @MainActor func disconnect() async { disconnects += 1; events.send(.ended(.hungUp)) }
    @MainActor func setMicrophoneMuted(_ muted: Bool) async throws {}
    @MainActor func flipCamera() async throws {}
    @MainActor func setFlashlight(_ on: Bool) async throws {}
}

private actor RingSleepRecorder {
    var durations: [Duration] = []
    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        try await Task.sleep(for: .milliseconds(30))
    }
}
