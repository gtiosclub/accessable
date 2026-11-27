import LiveKit
import SwiftUI

struct IncomingVolunteerCallView: View {
    let model: IncomingCallViewModel
    let video: any VideoCallSession
    /// The volunteer, for their picture in the corner while their camera is off.
    var myID: String?
    var myName = "You"
    @AccessibilityFocusState private var acceptFocused: Bool
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @State private var connectedAt: Date?
    @State private var videoIsBright = false
    @State private var controlsFolded = false

    var body: some View {
        Group {
            if model.phase == .ringing || model.phase == .idle {
                ringingBanner
            } else {
                activeCall
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) {
            if model.phase == .ringing { model.decline() } else { model.endCall() }
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .connected, connectedAt == nil { connectedAt = .now }
            if voiceOverEnabled, phase == .accepting || phase == .connecting {
                AccessibilityNotification.Announcement(title).post()
            }
        }
        .onChange(of: model.isMuted) { _, muted in
            if voiceOverEnabled, model.phase == .connected {
                AccessibilityNotification.Announcement(muted ? "Microphone muted" : "Microphone on").post()
            }
        }
        .task(id: model.call?.id) {
            acceptFocused = true
            // Let focus settle, then announce the name once, not on every heartbeat/re-render.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            model.announceIncomingCall()
        }
    }

    /// The design's "is calling you" card over the dimmed home screen.
    private var ringingBanner: some View {
        let name = model.call?.callerFirstName ?? "Caller"
        return ZStack(alignment: .top) {
            Color.black.opacity(0.7).ignoresSafeArea().accessibilityHidden(true)
            HStack(spacing: 12) {
                PersonAvatar(isOnline: nil, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline).accessibilityAddTraits(.isHeader)
                    Text("Is calling you").font(.footnote)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(title)
                .accessibilityHint("Answer within 30 seconds.")
                Spacer(minLength: 8)
                CallControlButton(systemImage: "phone.fill", label: "Accept",
                                  hint: "Answers the call and connects your microphone", diameter: 48) { model.accept() }
                    .accessibilityFocused($acceptFocused)
                CallControlButton(systemImage: "phone.down.fill", label: "Decline",
                                  hint: "Declines this call and returns to volunteer home", style: .end, diameter: 48) {
                    model.decline()
                }
            }
            .padding(14)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.3)))
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    /// The caller's camera full screen, their name at the top, the volunteer's own face or picture
    /// in the corner, controls down the right.
    private var activeCall: some View {
        let name = model.call?.callerFirstName ?? "Caller"
        let connected = model.phase == .connected
        let session = video as? LiveKitVideoCallSession
        return ZStack {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                CallVideoBackground(
                    track: connected ? session?.remoteVideoTrack : nil,
                    label: "Live video from the caller's camera",
                    isBright: $videoIsBright)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    CallTitleBlock(name: name,
                                   status: connected ? nil : (model.phase == .calling ? "Calling…" : "Connecting…"),
                                   connectedSince: connected ? connectedAt : nil)
                    Spacer(minLength: 8)
                    if connected {
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            CallPictureInPicture(track: model.isCameraOn ? session?.localVideoTrack : nil,
                                                 userID: myID, name: myName)
                        }
                    }
                }
                if let message = model.message {
                    Text(message).font(.callout)
                        .padding(10).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                }
                Spacer(minLength: 16)
                HStack {
                    Spacer()
                    CallControlsColumn(isFolded: $controlsFolded, endLabel: "End call",
                                       onEnd: { model.endCall() }) {
                        if connected { controls }
                    }
                    .disabled(model.phase == .ending)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .environment(\.callBackgroundIsBright, connected && videoIsBright)
    }

    @ViewBuilder private var controls: some View {
        CallControlButton(systemImage: "arrow.triangle.2.circlepath.camera", label: "Flip camera",
                          hint: "Switches between your front and back camera") {
            Task { await model.flipCamera() }
        }
        .disabled(!model.isCameraOn || model.isUpdatingControls)
        CallControlButton(systemImage: model.isMuted ? "mic.slash.fill" : "mic.fill",
                          label: model.isMuted ? "Unmute microphone" : "Mute microphone",
                          hint: "Changes your microphone",
                          value: model.isMuted ? "Muted" : "On",
                          style: model.isMuted ? .toggledOn : .standard) {
            Task { await model.toggleMute() }
        }
        .disabled(model.isUpdatingControls)
        CallControlButton(systemImage: model.isCameraOn ? "video.fill" : "video.slash.fill",
                          label: model.isCameraOn ? "Turn camera off" : "Turn camera on",
                          hint: model.isCameraOn ? "The caller sees your picture instead" : "Lets the caller see your face",
                          value: model.isCameraOn ? "On" : "Off",
                          style: model.isCameraOn ? .standard : .toggledOn) {
            Task { await model.toggleCamera() }
        }
        .disabled(model.isUpdatingControls)
    }

    private var title: String {
        let name = model.call?.callerFirstName ?? "Caller"
        switch model.phase {
        case .idle, .ringing: return "Incoming call from \(name)"
        case .calling: return "Calling \(name)"
        case .accepting: return "Answering \(name)…"
        case .connecting: return "Connecting to \(name)…"
        case .connected: return "Connected to \(name)"
        case .ending: return "Ending call…"
        }
    }
}
