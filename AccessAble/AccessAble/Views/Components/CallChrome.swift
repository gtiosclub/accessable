import LiveKit
import SwiftUI

// The in-call look shared by the caller and the volunteer: video behind, the other person's name
// large at the top, round controls down the right.

/// A round call control: cyan by default, black with a white ring when "on" (muted), red to end.
struct CallControlButton: View {
    enum Style { case standard, toggledOn, end }

    let systemImage: String
    let label: String
    var hint: String = ""
    var value: String?
    var style: Style = .standard
    var diameter: CGFloat = 60
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: diameter * 0.38, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: diameter, height: diameter)
                .background(background, in: Circle())
                .overlay { if style == .toggledOn { Circle().strokeBorder(.white, lineWidth: 2) } }
                .opacity(isEnabled ? 1 : Theme.dimmedOpacity)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityValue(value ?? "")
    }

    private var foreground: Color {
        switch style {
        case .standard: .black
        case .toggledOn, .end: .white
        }
    }

    private var background: Color {
        switch style {
        case .standard: Theme.cyan
        case .toggledOn: .black
        case .end: Theme.red
        }
    }
}

/// "0:45" since the call connected. VoiceOver reads it on request, not every second.
struct CallTimer: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.subheadline.monospacedDigit())
                .accessibilityLabel("Call time, \(Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide)))")
        }
    }
}

/// The name block at the top of a call: an optional small status line, the name, the timer.
struct CallTitleBlock: View {
    let name: String
    var status: String?
    var connectedSince: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let status {
                Text(status.uppercased()).font(.subheadline.weight(.medium))
            }
            Text(name)
                .font(.system(size: 36, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            if let connectedSince { CallTimer(since: connectedSince) }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 4)
    }
}

/// A LiveKit track filling the screen, or the dark call background without one.
struct CallVideoBackground: View {
    let track: VideoTrack?
    var mirrored = false
    var label: String

    var body: some View {
        ZStack {
            Color(white: 0.2)
            if let track {
                SwiftUIVideoView(track, layoutMode: .fill, mirrorMode: mirrored ? .mirror : .off)
                    .accessibilityLabel(label)
            }
        }
        .ignoresSafeArea()
    }
}
