import LiveKit
import SwiftUI

/// A call has separate progress/controls and terminal results; neither needs sight to operate.
struct CallView: View {
    @State private var viewModel: CallViewModel
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @AccessibilityFocusState private var statusFocused: Bool
    @State private var connectedAt: Date?
    @State private var videoIsBright = false
    private let onClose: () -> Void
    private let safety: any CallSafetyService
    private let video: any VideoCallSession

    init(services: AppServices, volunteer: Volunteer?, onClose: @escaping () -> Void) {
        _viewModel = State(initialValue: CallViewModel(services: services, volunteer: volunteer))
        self.onClose = onClose
        safety = services.callSafety
        video = services.videoCall
    }

    private var hasFinished: Bool {
        if case .ended = viewModel.state { return true }
        if case .failed = viewModel.state { return true }
        return false
    }

    var body: some View {
        Group {
            if hasFinished {
                EndOfCallView(status: viewModel.statusText, failure: viewModel.failure,
                    summary: viewModel.lastCallForSafety, safety: safety,
                    onRetry: { viewModel.retry() }, onOpenSettings: {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }, onClose: onClose)
            } else {
                activeCall
                    .accessibilityAction(.escape) { Task { await viewModel.hangUp() } }
            }
        }
        .foregroundStyle(.white).background(Color.black.ignoresSafeArea())
        .onChange(of: viewModel.state) { _, state in
            if state == .connected, connectedAt == nil { connectedAt = .now }
            if state == .ringing { statusFocused = true }
            if state == .connecting || state == .connected {
                if voiceOverEnabled {
                    let light = state == .connected && viewModel.isFlashlightOn ? ". Flashlight on." : ""
                    AccessibilityNotification.Announcement(viewModel.statusText + light).post()
                }
            }
        }
        .onChange(of: viewModel.isMuted) { _, muted in
            if voiceOverEnabled, viewModel.state == .connected {
                AccessibilityNotification.Announcement(muted ? "Microphone muted" : "Microphone on").post()
            }
        }
        .onChange(of: viewModel.isUsingBackCamera) { _, back in
            if voiceOverEnabled, viewModel.state == .connected {
                AccessibilityNotification.Announcement(back ? "Back camera" : "Front camera").post()
            }
        }
        .onChange(of: viewModel.isFlashlightOn) { _, on in
            if voiceOverEnabled, viewModel.state == .connected {
                AccessibilityNotification.Announcement(on ? "Flashlight on" : "Flashlight off").post()
            }
        }
        .onChange(of: viewModel.controlError) { _, error in
            if let error { AccessibilityNotification.Announcement(error).post() }
        }
        .task { statusFocused = true; await viewModel.start() }
        // Leaving the screen mid-call hangs up, which also gives the camera back to AR.
        .onDisappear { Task { await viewModel.hangUp() } }
        .accessibilityAction(.magicTap) {
            if viewModel.state.isActive { Task { await viewModel.hangUp() } }
        }
    }

    /// The design's call screen: their name over your camera, controls down the right.
    private var activeCall: some View {
        let connected = viewModel.state == .connected
        return ZStack {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                CallVideoBackground(
                    track: connected ? (video as? LiveKitVideoCallSession)?.localVideoTrack : nil,
                    mirrored: !viewModel.isUsingBackCamera,
                    label: "Your camera, which the volunteer sees",
                    isBright: $videoIsBright)
            }
            VStack(alignment: .leading, spacing: 8) {
                CallTitleBlock(name: viewModel.title,
                               status: connected ? nil : "Calling…",
                               connectedSince: connected ? connectedAt : nil)
                Text(viewModel.statusText).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .callTextGlow()
                    .accessibilityFocused($statusFocused)
                if let error = viewModel.controlError {
                    Text(error).font(.callout).fixedSize(horizontal: false, vertical: true)
                        .padding(10).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                }
                Spacer(minLength: 16)
                HStack(alignment: .bottom) {
                    if connected {
                        CallControlButton(systemImage: "arrow.triangle.2.circlepath.camera", label: "Flip camera",
                            hint: viewModel.isUsingBackCamera ? "Switches to the front camera" : "Switches to the back camera",
                            value: viewModel.isUsingBackCamera ? "Back camera" : "Front camera") {
                            Task { await viewModel.flipCamera() }
                        }
                    }
                    Spacer()
                    VStack(spacing: 16) {
                        if connected { controls }
                        if viewModel.state.isActive {
                            CallControlButton(systemImage: "phone.down.fill",
                                label: viewModel.state == .ringing ? "Cancel call" : "End call",
                                hint: "Ends this call and opens call results", style: .end) {
                                Task { await viewModel.hangUp() }
                            }
                        }
                    }
                }
                .disabled(viewModel.isUpdatingControls)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .environment(\.callBackgroundIsBright, connected && videoIsBright)
    }

    @ViewBuilder private var controls: some View {
        CallControlButton(systemImage: viewModel.isMuted ? "mic.slash.fill" : "mic.fill",
            label: viewModel.isMuted ? "Unmute microphone" : "Mute microphone",
            hint: viewModel.isMuted ? "Lets the volunteer hear you" : "Stops sending your voice",
            value: viewModel.isMuted ? "Muted" : "On",
            style: viewModel.isMuted ? .toggledOn : .standard) {
            Task { await viewModel.toggleMute() }
        }
        CallControlButton(systemImage: viewModel.isFlashlightOn ? "flashlight.on.fill" : "flashlight.off.fill",
            label: "Flashlight",
            hint: viewModel.isUsingBackCamera ? "Lights what the back camera sees" : "Switch to the back camera to use the flashlight",
            value: viewModel.isFlashlightOn ? "On" : "Off",
            style: viewModel.isFlashlightOn ? .toggledOn : .standard) {
            Task { await viewModel.toggleFlashlight() }
        }
        .disabled(!viewModel.isUsingBackCamera)
    }
}

#Preview {
    CallView(services: .preview, volunteer: SampleContent.activeVolunteers.first) {}
}
