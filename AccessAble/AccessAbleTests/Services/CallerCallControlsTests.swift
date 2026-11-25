import Foundation
import Testing
@testable import AccessAble

@MainActor
struct CallerCallControlsTests {
    @Test func torchStartsOffByDefault() async throws {
        let (model, video, _) = harness()
        await model.start()
        try await waitFor { model.state == .connected }
        #expect(video.torchRequests.isEmpty)
        await model.hangUp()
    }

    @Test func savedTorchPreferenceIsAppliedOnlyAfterConnectionAndReleasedOnHangup() async throws {
        let (model, video, settings) = harness()
        settings.preferences.flashlightOnStart = true
        await model.start()
        try await waitFor { model.state == .connected }
        #expect(video.torchRequests == [true])
        #expect(model.isFlashlightOn && video.torchOn)
        #expect(!video.torchRequestedBeforeConnection)
        await model.hangUp()
        #expect(!video.torchOn)
    }

    @Test func unsupportedTorchDoesNotFailTheCall() async throws {
        let (model, video, settings) = harness()
        settings.preferences.flashlightOnStart = true
        video.failTorch = true
        await model.start()
        try await waitFor { model.state == .connected }
        #expect(model.controlError != nil)
        #expect(!model.isFlashlightOn)
        #expect(video.connected)
        await model.hangUp()
    }

    @Test func retryUsesTheLatestPreferenceAndKeepsTheAcceptedCallSafetySummary() async throws {
        let (model, video, settings) = harness()
        await model.start()
        try await waitFor { model.state == .connected }
        await model.hangUp()
        #expect(model.lastCallForSafety?.id == "control-1")
        settings.preferences.flashlightOnStart = true
        model.retry()
        try await waitFor { model.state == .connected && video.connections == 2 }
        #expect(video.torchOn)
        #expect(model.lastCallForSafety?.id == "control-2")
        await model.hangUp()
    }

    @Test func lateMuteResultCannotChangeTheNextCallsAccessibleState() async throws {
        let (model, video, _) = harness()
        await model.start()
        try await waitFor { model.state == .connected }
        video.pauseMute = true
        let muting = Task { await model.toggleMute() }
        await video.waitForMute()
        await model.hangUp()
        model.retry()
        try await waitFor { model.state == .connected && video.connections == 2 }
        video.resumeMute()
        await muting.value
        #expect(!model.isMuted)
        await model.hangUp()
    }

    private func harness() -> (CallViewModel, ControlsTestVideo, CallerSettings) {
        var services = AppServices.preview
        let video = ControlsTestVideo()
        services.callSignaling = ControlsTestSignaling()
        services.videoCall = video
        services.announcements = PlaceholderAnnouncementEngine()
        return (CallViewModel(services: services, volunteer: nil, permissionCheck: { nil }), video, services.callerSettings)
    }
    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CallSessionError.notConfigured
    }
}

@MainActor
private final class ControlsTestSignaling: CallSignaling {
    private var count = 0
    func requestCall(preferring volunteerID: String?, progress: @Sendable (CallRequestProgress) -> Void) async throws -> CallTicket {
        count += 1
        return CallTicket(callID: "control-\(count)", roomName: "room", token: "fixture", callerID: "caller",
                          volunteerID: "helper", expiresAt: .now.addingTimeInterval(60))
    }
    func accept(callID: String) async throws -> CallTicket { throw CallSessionError.notConfigured }
    func decline(callID: String) async throws {}
    func skip(callID: String) async throws {}
    func endCall(callID: String) async {}
}

@MainActor
private final class ControlsTestVideo: VideoCallSession {
    private nonisolated let events = Broadcaster<CallState>(replaysLatest: true)
    var connected = false
    var connections = 0
    var failTorch = false
    var torchOn = false
    var torchRequests: [Bool] = []
    var torchRequestedBeforeConnection = false
    var pauseMute = false
    private var pendingMute: CheckedContinuation<Void, Never>?
    private var muteWaiter: CheckedContinuation<Void, Never>?
    func waitForMute() async {
        if pendingMute != nil { return }
        await withCheckedContinuation { muteWaiter = $0 }
    }
    func resumeMute() { pauseMute = false; pendingMute?.resume(); pendingMute = nil }
    init() { events.send(.idle) }
    nonisolated func states() -> AsyncStream<CallState> { events.stream() }
    func connect(with ticket: CallTicket) async throws { connected = true; connections += 1; events.send(.connected) }
    func disconnect() async { connected = false; torchOn = false; events.send(.ended(.hungUp)) }
    func setMicrophoneMuted(_ muted: Bool) async throws {
        if pauseMute { await withCheckedContinuation { pendingMute = $0; muteWaiter?.resume(); muteWaiter = nil } }
    }
    func flipCamera() async throws {}
    func setFlashlight(_ on: Bool) async throws {
        torchRequestedBeforeConnection = torchRequestedBeforeConnection || !connected
        torchRequests.append(on)
        if failTorch { throw CallSessionError.notConfigured }
        torchOn = on
    }
}
