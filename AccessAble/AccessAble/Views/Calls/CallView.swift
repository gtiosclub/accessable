import SwiftUI

/// Owner: Calls (VOLUNTEER-5). The in-call screen: status, Mute, Flip camera, flashlight and End.
struct CallView: View {
    @State private var viewModel: CallViewModel
    private let onClose: () -> Void

    init(services: AppServices, partnerID: String, partnerName: String, onClose: @escaping () -> Void) {
        _viewModel = State(initialValue: CallViewModel(
            services: services, partnerID: partnerID, partnerName: partnerName))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(viewModel.partnerName)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text(viewModel.statusText)
                .font(.title3)
                .multilineTextAlignment(.center)
            Spacer()

            if viewModel.state.isActive {
                controls
            } else {
                AccessibleActionButton(title: "Close", systemImage: "xmark",
                                       hint: "Returns to the previous screen", action: onClose)
            }

            if let error = viewModel.controlError {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        .padding(24)
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        // Every state change is spoken, so a VoiceOver user always knows where the call is.
        .onChange(of: viewModel.statusText) { _, text in
            AccessibilityNotification.Announcement(text).post()
        }
        .task { await viewModel.start() }
        // Leaving the screen mid-call hangs up, which also gives the camera back to AR.
        .onDisappear { Task { await viewModel.hangUp() } }
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
}

#Preview {
    CallView(services: .preview, partnerID: "shruthi", partnerName: "Shruthi") {}
        .environment(AppViewModel.preview)
}
