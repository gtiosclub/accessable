import SwiftUI

/// A call has separate progress/controls and terminal results; neither needs sight to operate.
struct CallView: View {
    @State private var viewModel: CallViewModel
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @AccessibilityFocusState private var statusFocused: Bool
    private let onClose: () -> Void
    private let safety: any CallSafetyService

    init(services: AppServices, volunteer: Volunteer?, onClose: @escaping () -> Void) {
        _viewModel = State(initialValue: CallViewModel(services: services, volunteer: volunteer))
        self.onClose = onClose
        safety = services.callSafety
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
                ScrollView {
                    VStack(spacing: 24) {
                        Text(viewModel.title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                        Text(viewModel.statusText).font(.title3).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityFocused($statusFocused)
                        if viewModel.state == .ringing || viewModel.state == .connecting {
                            ProgressView().controlSize(.large).accessibilityHidden(true)
                        }
                        if viewModel.state == .connected { controls }
                        if let error = viewModel.controlError {
                            Text(error).font(.body).fixedSize(horizontal: false, vertical: true)
                        }
                        if viewModel.state.isActive {
                            AccessibleActionButton(title: viewModel.state == .ringing ? "Cancel call" : "End call",
                                systemImage: "phone.down.fill", hint: "Ends this call and opens call results",
                                role: .destructive) { Task { await viewModel.hangUp() } }
                        }
                    }.padding(24).frame(maxWidth: .infinity)
                }
                .accessibilityAction(.escape) { Task { await viewModel.hangUp() } }
            }
        }
        .foregroundStyle(.white).background(Color.black.ignoresSafeArea())
        .onChange(of: viewModel.state) { _, state in
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
        .onDisappear { Task { await viewModel.hangUp() } }
        .accessibilityAction(.magicTap) {
            if viewModel.state.isActive { Task { await viewModel.hangUp() } }
        }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            AccessibleActionButton(title: viewModel.isMuted ? "Unmute microphone" : "Mute microphone",
                systemImage: viewModel.isMuted ? "mic.slash.fill" : "mic.fill",
                hint: viewModel.isMuted ? "Lets the volunteer hear you" : "Stops sending your voice") {
                    Task { await viewModel.toggleMute() }
                }
                .accessibilityValue(viewModel.isMuted ? "Muted" : "On")
            AccessibleActionButton(title: "Flip camera", systemImage: "arrow.triangle.2.circlepath.camera",
                hint: viewModel.isUsingBackCamera ? "Switches to the front camera" : "Switches to the back camera") {
                    Task { await viewModel.flipCamera() }
                }
                .accessibilityValue(viewModel.isUsingBackCamera ? "Back camera" : "Front camera")
            Toggle("Flashlight", isOn: Binding(get: { viewModel.isFlashlightOn }, set: { _ in
                Task { await viewModel.toggleFlashlight() }
            }))
                .font(.title3).frame(minHeight: 44)
                .disabled(!viewModel.isUsingBackCamera)
                .accessibilityHint(viewModel.isUsingBackCamera ? "Lights what the back camera sees" : "Switch to the back camera to use the flashlight")
        }
        .disabled(viewModel.isUpdatingControls)
    }
}

#Preview {
    CallView(services: .preview, volunteer: SampleContent.activeVolunteers.first) {}
}
