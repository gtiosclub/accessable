import LiveKit
import SwiftUI

struct IncomingVolunteerCallView: View {
    let model: IncomingCallViewModel
    let video: any VideoCallSession
    @AccessibilityFocusState private var acceptFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "phone.arrow.down.left.fill")
                    .font(.system(size: 60)).accessibilityHidden(true)
                Text(title).font(.largeTitle.bold()).multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if model.phase == .ringing {
                    Text("Answer within 30 seconds.").font(.body)
                    AccessibleActionButton(title: "Accept", systemImage: "phone.fill",
                                           hint: "Answers the call and connects your microphone") { model.accept() }
                        .accessibilityFocused($acceptFocused)
                    AccessibleActionButton(title: "Decline", systemImage: "phone.down.fill",
                                           hint: "Declines this call and returns to volunteer home", role: .destructive) {
                        model.decline()
                    }
                } else {
                    if model.phase == .connected {
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            if let track = (video as? LiveKitVideoCallSession)?.remoteVideoTrack {
                                SwiftUIVideoView(track, layoutMode: .fit, mirrorMode: .off)
                                    .frame(height: 280).background(.black)
                                    .accessibilityLabel("Live video from the caller's camera")
                            } else { Text("Waiting for caller video") }
                        }
                        AccessibleActionButton(title: model.isMuted ? "Unmute" : "Mute",
                                               systemImage: model.isMuted ? "mic.slash.fill" : "mic.fill",
                                               hint: "Changes your microphone") {
                            Task { await model.toggleMute() }
                        }
                    } else { ProgressView().accessibilityLabel(title) }
                    if let message = model.message { Text(message) }
                    AccessibleActionButton(title: "End call", systemImage: "phone.down.fill",
                                           hint: "Ends this call", role: .destructive) { model.endCall() }
                        .disabled(model.phase == .ending)
                }
            }.padding(24).frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) {
            if model.phase == .ringing { model.decline() } else { model.endCall() }
        }
        .task(id: model.call?.id) {
            acceptFocused = true
            // Let focus settle, then announce the name once, not on every heartbeat/re-render.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            model.announceIncomingCall()
        }
    }

    private var title: String {
        let name = model.call?.callerFirstName ?? "Caller"
        switch model.phase {
        case .idle, .ringing: return "Incoming call from \(name)"
        case .accepting: return "Answering \(name)…"
        case .connecting: return "Connecting to \(name)…"
        case .connected: return "Connected to \(name)"
        case .ending: return "Ending call…"
        }
    }
}
