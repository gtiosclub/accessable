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
    @State private var controlsFolded = false
    private let onClose: () -> Void
    private let safety: any CallSafetyService
    private let video: any VideoCallSession

    init(services: AppServices, volunteer: Volunteer?, answering: VolunteerRing? = nil, onClose: @escaping () -> Void) {
        _viewModel = State(initialValue: CallViewModel(services: services, volunteer: volunteer, answering: answering))
        self.onClose = onClose
        safety = services.callSafety
        video = services.videoCall
    }

    /// Only a call that couldn't happen keeps a results screen (with Try again); one that simply
    /// ended goes straight back to where the caller was.
    private var hasFinished: Bool {
        if case .ended = viewModel.state { return viewModel.failure != nil }
        if case .failed = viewModel.state { return true }
        return false
    }

    private var endedNormally: Bool {
        if case .ended = viewModel.state { return viewModel.failure == nil }
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
            } else if endedNormally {
                Color.black.ignoresSafeArea()
            } else {
                activeCall
                    .accessibilityAction(.escape) { Task { await viewModel.hangUp() } }
            }
        }
        .foregroundStyle(.white).background(Color.black.ignoresSafeArea())
        .onChange(of: viewModel.state) { _, state in
            if state == .connected, connectedAt == nil { connectedAt = .now }
            if case .ended = state, viewModel.failure == nil {
                AccessibilityNotification.Announcement(viewModel.statusText).post()
                onClose()
                return
            }
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

    /// The design's call screen: the volunteer's name over your camera, their face or picture in
    /// the corner, controls down the right.
    private var activeCall: some View {
        let connected = viewModel.state == .connected
        let session = video as? LiveKitVideoCallSession
        return ZStack {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                CallVideoBackground(
                    track: connected ? session?.localVideoTrack : nil,
                    mirrored: !viewModel.isUsingBackCamera,
                    label: "Your camera",
                    isBright: $videoIsBright)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    CallTitleBlock(name: viewModel.title,
                                   status: connected ? nil : "Calling…",
                                   connectedSince: connected ? connectedAt : nil)
                        // VoiceOver reads the full status here; the screen shows only the design's words.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(viewModel.title). \(viewModel.statusText)")
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($statusFocused)
                    Spacer(minLength: 8)
                    if connected {
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            CallPictureInPicture(track: session?.remoteVideoTrack,
                                                 userID: viewModel.lastCallForSafety?.otherUserID,
                                                 name: viewModel.volunteerName ?? "Volunteer")
                        }
                    }
                }
                if let error = viewModel.controlError {
                    Text(error).font(.callout).fixedSize(horizontal: false, vertical: true)
                        .padding(10).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                }
                Spacer(minLength: 16)
                HStack {
                    Spacer()
                    if viewModel.state.isActive {
                        CallControlsColumn(isFolded: $controlsFolded,
                                           endLabel: viewModel.state == .ringing ? "Cancel call" : "End call",
                                           endHint: "Ends this call",
                                           onEnd: { Task { await viewModel.hangUp() } }) {
                            if connected { controls }
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
        CallControlButton(systemImage: "arrow.triangle.2.circlepath.camera", label: "Flip camera",
            hint: viewModel.isUsingBackCamera ? "Switches to the front camera" : "Switches to the back camera",
            value: viewModel.isUsingBackCamera ? "Back camera" : "Front camera") {
            Task { await viewModel.flipCamera() }
        }
        .disabled(!viewModel.isCameraOn)
        CallControlButton(systemImage: viewModel.isMuted ? "mic.slash.fill" : "mic.fill",
            label: viewModel.isMuted ? "Unmute microphone" : "Mute microphone",
            hint: viewModel.isMuted ? "Lets the volunteer hear you" : "Stops sending your voice",
            value: viewModel.isMuted ? "Muted" : "On",
            style: viewModel.isMuted ? .toggledOn : .standard) {
            Task { await viewModel.toggleMute() }
        }
        CallControlButton(systemImage: viewModel.isCameraOn ? "video.fill" : "video.slash.fill",
            label: viewModel.isCameraOn ? "Turn camera off" : "Turn camera on",
            hint: viewModel.isCameraOn ? "The volunteer stops seeing your camera" : "Lets the volunteer see your camera",
            value: viewModel.isCameraOn ? "On" : "Off",
            style: viewModel.isCameraOn ? .standard : .toggledOn) {
            Task { await viewModel.toggleCamera() }
        }
    }
}

#Preview {
    CallView(services: .preview, volunteer: SampleContent.activeVolunteers.first) {}
}
