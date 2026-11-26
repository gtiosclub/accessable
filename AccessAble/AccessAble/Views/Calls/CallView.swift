import SwiftUI

/// Owner: Calls (VOLUNTEER-5, connecting and failures from VOLUNTEER-7). The call screen: ringing
/// progress, then Mute, Flip camera, flashlight and End; after a failure or the end of a call,
/// Try again (and Open Settings when a permission is off).
struct CallView: View {
    @State private var viewModel: CallViewModel
    @Environment(\.openURL) private var openURL
    private let onClose: () -> Void

    /// `volunteer` is rung first; nil rings whoever is free.
    init(services: AppServices, volunteer: Volunteer?, onClose: @escaping () -> Void) {
        _viewModel = State(initialValue: CallViewModel(services: services, volunteer: volunteer))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(viewModel.title)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            if viewModel.state == .ringing {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .accessibilityHidden(true)
            }
            Text(viewModel.statusText)
                .font(.title3)
                .multilineTextAlignment(.center)
            Spacer()

            if viewModel.state == .ringing {
                AccessibleActionButton(title: "Cancel call", systemImage: "phone.down.fill",
                                       hint: "Stops calling volunteers", role: .destructive) {
                    Task { await viewModel.hangUp() }
                }
            } else if viewModel.state.isActive {
                controls
            } else if viewModel.state != .idle {
                afterCallActions
            }

            if let error = viewModel.controlError {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        .padding(24)
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        // Ringing and failures are spoken by the announcement engine (CallViewModel.say); during
        // the call the engine stays quiet, so VoiceOver announces connecting and connected.
        .onChange(of: viewModel.statusText) { _, text in
            if viewModel.state == .connecting || viewModel.state == .connected {
                AccessibilityNotification.Announcement(text).post()
            }
        }
        .onChange(of: viewModel.controlError) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .task { await viewModel.start() }
        // Leaving the screen mid-call hangs up, which also gives the camera back to AR.
        .onDisappear { Task { await viewModel.hangUp() } }
        .accessibilityAction(.escape) {
            Task { await viewModel.hangUp() }
            onClose()
        }
    }

    @ViewBuilder
    private var controls: some View {
        AccessibleActionButton(
            title: viewModel.isMuted ? "Unmute" : "Mute",
            systemImage: viewModel.isMuted ? "mic.slash.fill" : "mic.fill",
            hint: viewModel.isMuted ? "Turns your microphone back on" : "Turns your microphone off"
        ) {
            Task { await viewModel.toggleMute() }
        }

        AccessibleActionButton(
            title: "Flip camera",
            systemImage: "arrow.triangle.2.circlepath.camera",
            hint: viewModel.isUsingBackCamera ? "Switches to the front camera" : "Switches to the back camera"
        ) {
            Task { await viewModel.flipCamera() }
        }

        Toggle(isOn: Binding(
            get: { viewModel.isFlashlightOn },
            set: { _ in Task { await viewModel.toggleFlashlight() } }
        )) {
            Label("Flashlight", systemImage: "flashlight.on.fill")
        }
        .font(.title3)
        .frame(minHeight: 64)
        .disabled(!viewModel.isUsingBackCamera)
        .accessibilityHint("Lights up what the back camera sees")

        AccessibleActionButton(title: "End call", systemImage: "phone.down.fill",
                               hint: "Hangs up", role: .destructive) {
            Task { await viewModel.hangUp() }
        }
    }

    /// Every failure gets Try again; a permission that's off also gets Open Settings.
    @ViewBuilder
    private var afterCallActions: some View {
        if let failure = viewModel.failure, failure.needsSettings {
            AccessibleActionButton(title: "Open Settings", systemImage: "gear",
                                   hint: "Opens AccessAble's settings so you can turn access on") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        }

        AccessibleActionButton(
            title: viewModel.failure == nil ? "Call again" : "Try again",
            systemImage: "arrow.clockwise",
            hint: "Calls a volunteer again"
        ) {
            viewModel.retry()
        }

        AccessibleActionButton(title: "Close", systemImage: "xmark",
                               hint: "Returns to the previous screen", action: onClose)
    }
}

#Preview {
    CallView(services: .preview, volunteer: SampleContent.activeVolunteers.first) {}
}
