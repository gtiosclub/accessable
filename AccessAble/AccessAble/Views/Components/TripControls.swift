import SwiftUI

enum TripControl: Hashable {
    case callHelp
    case microphone
    case pauseTrip
}

/// Bottom panel on the trip screen: Call Help, microphone, Pause Trip.
/// Controls in `disabled` are dimmed and inert (used by the tutorial).
struct TripControlPanel: View {
    var isMicMuted: Bool
    var disabled: Set<TripControl> = []
    var onCallHelp: () -> Void = {}
    var onMicrophone: () -> Void = {}
    var onPauseTrip: () -> Void = {}

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                Button("Call Help", action: onCallHelp)
                    .buttonStyle(.pill(.primary))
                    .disabled(disabled.contains(.callHelp))
                    .accessibilityHint("Video call a volunteer")

                CircleIconButton(
                    systemImage: isMicMuted ? "mic.slash" : "mic.fill",
                    label: isMicMuted ? "Unmute microphone" : "Mute microphone",
                    hint: "Lets the AI agent hear your commands and questions",
                    fill: Theme.red,
                    foreground: .white,
                    diameter: 56,
                    action: onMicrophone
                )
                .disabled(disabled.contains(.microphone))
            }
            Button("Pause Trip", action: onPauseTrip)
                .buttonStyle(.pill(.destructive))
                .disabled(disabled.contains(.pauseTrip))
                .accessibilityHint("Opens settings, continue, exit, and call help")
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 36, topTrailingRadius: 36, style: .continuous)
                .fill(Theme.panel)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

/// Stack of recent spoken announcements above the control panel. Newest is at the bottom;
/// older ones fade.
struct AnnouncementStack: View {
    let announcements: [TripAnnouncement]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(announcements.enumerated()), id: \.element.id) { index, announcement in
                let isOld = index < announcements.count - 2
                Text(announcement.text)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(announcement.kind == .warning ? .white : .black)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        announcement.kind == .warning ? Theme.red : Theme.cyan,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )
                    .opacity(isOld ? 0.7 : 1)
                    .accessibilityLabel(announcement.kind == .warning ? "Warning: \(announcement.text)" : announcement.text)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: announcements)
    }
}

#Preview {
    ZStack(alignment: .bottom) {
        CameraBackdrop()
        VStack(spacing: 12) {
            AnnouncementStack(announcements: SampleContent.initialAnnouncements).padding(.horizontal, 24)
            TripControlPanel(isMicMuted: true)
        }
    }
}
