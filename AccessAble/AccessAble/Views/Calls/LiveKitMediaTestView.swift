#if DEBUG
import LiveKit
import SwiftUI

/// Bare transport harness, not the final calling UI. Only the dedicated Debug scheme opens it.
struct LiveKitMediaTestView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: LiveKitMediaTestModel
    @State private var role: LiveKitMediaTestModel.Role = .caller
    @State private var isRendering = false

    init(services: AppServices) {
        _model = State(initialValue: LiveKitMediaTestModel(scene: services.scene))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Development test only. Media is shared live with everyone in this test room.")
                        .font(.callout)
                    Text("Room: \(LiveKitMediaTestModel.roomName)").font(.caption.monospaced())
                    Picker("This phone's role", selection: $role) {
                        Text("Caller").tag(LiveKitMediaTestModel.Role.caller)
                        Text("Volunteer").tag(LiveKitMediaTestModel.Role.volunteer)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.phase != .idle)
                    Text(model.message).accessibilityIdentifier("mediaTestStatus")
                    if let warning = model.guidanceWarning { Text(warning).foregroundStyle(.orange) }
                    if let track = model.remoteVideo {
                        Text("Received caller video")
                        SwiftUIVideoView(track, layoutMode: .fit, mirrorMode: .off, isRendering: $isRendering)
                            .frame(height: 300)
                            .background(.black)
                            .accessibilityLabel("Live video from the caller's rear camera")
                        Text(isRendering ? "Receiving video frames" : "Waiting for video frames")
                    } else if let track = model.localVideo {
                        Text("Your rear camera (local preview)")
                        SwiftUIVideoView(track, layoutMode: .fit, mirrorMode: .off)
                            .frame(height: 240)
                            .background(.black)
                    }
                    Group {
                        Text("Connection: \(model.connection)")
                        Text("Other participants: \(model.peerCount)")
                        Text("Microphone published: \(model.microphonePublished ? "yes" : "no")")
                        Text("Subscribed remote audio tracks: \(model.remoteAudioCount)")
                        Text("Remote voice detected: \(model.remoteIsSpeaking ? "yes" : "no")")
                    }.font(.caption)
                    Text("Audio diagnostics do not prove audibility. Speak a phrase in each direction and have the other person repeat it.")
                        .font(.footnote)
                    if model.phase == .idle {
                        Button("Join as \(role.rawValue)") { model.start(role: role) }
                            .buttonStyle(.borderedProminent).frame(minHeight: 44)
                    } else {
                        Button(model.phase == .leaving ? "Disconnecting…" : "Disconnect") { model.stop() }
                            .buttonStyle(.bordered).frame(minHeight: 44)
                            .disabled(model.phase == .leaving)
                    }
                }.padding()
            }
            .navigationTitle("LiveKit Media Test")
        }
        .onChange(of: scenePhase) { _, phase in
            // Permission dialogs briefly make the app inactive; only background ends the test.
            if phase == .background { model.stop() }
        }
        .onDisappear { model.stop() }
        .onChange(of: model.phase) { _, phase in
            if phase == .idle { isRendering = false }
        }
    }
}
#endif
