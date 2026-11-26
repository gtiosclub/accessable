import Foundation
import Testing
@testable import AccessAble

@MainActor
struct CallIntegrationTests {
    @Test func fiveCallerCyclesDoNotNeedANewModelOrSession() async throws {
        let signaling = CycleSignaling(), video = CycleVideo()
        var services = AppServices.preview
        services.callSignaling = signaling
        services.videoCall = video
        let model = CallViewModel(services: services, volunteer: nil, permissionCheck: { nil })
        let listener = Task { await model.start() }
        defer { listener.cancel() }
        for attempt in 1...5 {
            if attempt > 1 { model.retry() }
            try await waitFor { model.state == .connected && video.connections == attempt }
            await model.hangUp()
            #expect(model.state == .ended(.hungUp))
            #expect(signaling.active.isEmpty)
            #expect(!video.connected)
        }
        #expect(signaling.requests == 5)
        #expect(Set(signaling.ended).count == 5)
    }

    @Test func failedMediaJoinFreesReservationAndCanRetry() async throws {
        let signaling = CycleSignaling(), video = CycleVideo()
        video.failNext = true
        var services = AppServices.preview
        services.callSignaling = signaling; services.videoCall = video
        let model = CallViewModel(services: services, volunteer: nil, permissionCheck: { nil })
        let listener = Task { await model.start() }
        defer { listener.cancel() }
        try await waitFor { if case .failed = model.state { return true }; return false }
        #expect(signaling.active.isEmpty)
        model.retry()
        try await waitFor { model.state == .connected }
        await model.hangUp()
        #expect(signaling.active.isEmpty)
        #expect(signaling.requests == 2)
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CycleError.failed
    }
}

private enum CycleError: Error { case failed }

@MainActor
private final class CycleSignaling: CallSignaling {
    var requests = 0
    var active: Set<String> = []
    var ended: [String] = []
    @MainActor func requestCall(preferring volunteerID: String?, progress: @Sendable (CallRequestProgress) -> Void) async throws -> CallTicket {
        requests += 1
        let id = "cycle-\(requests)"
        active.insert(id)
        return CallTicket(callID: id, roomName: id, token: "fake", callerID: "caller", volunteerID: "helper", expiresAt: .now.addingTimeInterval(60))
    }
    @MainActor func accept(callID: String) async throws -> CallTicket { throw CycleError.failed }
    @MainActor func decline(callID: String) async throws {}
    @MainActor func skip(callID: String) async throws {}
    @MainActor func endCall(callID: String) async { active.remove(callID); ended.append(callID) }
}

@MainActor
private final class CycleVideo: VideoCallSession {
    private nonisolated let events = Broadcaster<CallState>(replaysLatest: true)
    var connections = 0
    var connected = false
    var failNext = false
    init() { events.send(.idle) }
    nonisolated func states() -> AsyncStream<CallState> { events.stream() }
    @MainActor func connect(with ticket: CallTicket) async throws {
        connections += 1
        events.send(.connecting)
        if failNext { failNext = false; events.send(.failed("fixture failure")); throw CycleError.failed }
        connected = true
        events.send(.connected)
    }
    @MainActor func disconnect() async {
        guard connected else { return }
        connected = false
        events.send(.ended(.hungUp))
    }
    @MainActor func setMicrophoneMuted(_ muted: Bool) async throws {}
    @MainActor func flipCamera() async throws {}
    @MainActor func setFlashlight(_ on: Bool) async throws {}
}
