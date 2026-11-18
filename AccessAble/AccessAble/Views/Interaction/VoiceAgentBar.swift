import SwiftUI

/// Owner: User Interaction (3.1). The strip along the bottom of every main screen: what the
/// voice agent is doing, what it last said, and the mute button.
struct VoiceAgentBar: View {
    let agent: VoiceAgentViewModel
    var onAddKey: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .font(.title3)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // One element; the live words aren't read out, or VoiceOver would talk over the user.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Voice assistant: \(accessibilityTitle)")
            .accessibilityValue(detail ?? "")

            if agent.status == .needsKey {
                Button("Add Key", action: onAddKey)
                    .buttonStyle(.pill(.primary, size: .compact))
                    .fixedSize()
                    .accessibilityHint("Opens Settings to enter a Claude API key")
            } else {
                CircleIconButton(
                    systemImage: agent.isMuted ? "mic.slash.fill" : "mic.fill",
                    label: agent.isMuted ? "Unmute voice assistant" : "Mute voice assistant",
                    hint: agent.isMuted ? "Starts listening for commands" : "Stops listening until you unmute",
                    fill: agent.isMuted ? Theme.red : Theme.cyan,
                    foreground: agent.isMuted ? .white : .black,
                    diameter: 48
                ) {
                    Task {
                        await agent.toggleMute()
                        AccessibilityNotification.Announcement(agent.isMuted ? "Voice assistant muted" : "Voice assistant listening").post()
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.35)))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .animation(.easeInOut(duration: 0.2), value: agent.status)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch agent.status {
        case .listening:
            Image(systemName: "waveform").foregroundStyle(Theme.cyan)
        case .hearing:
            Image(systemName: "waveform")
                .foregroundStyle(Theme.cyan)
                .symbolEffect(.variableColor.iterative)
        case .thinking, .starting:
            ProgressView().tint(.white)
        case .confirming:
            Image(systemName: "questionmark.bubble.fill").foregroundStyle(Theme.sparkle)
        case .muted, .pausedForDictation:
            Image(systemName: "mic.slash").foregroundStyle(.white.opacity(0.7))
        case .needsKey, .unavailable:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.sparkle)
        }
    }

    private var title: String {
        switch agent.status {
        case .needsKey: "Voice assistant needs a Claude API key"
        case .muted: "Voice assistant muted"
        case .starting: "Starting voice assistant…"
        case .listening: "Listening…"
        case .hearing(let words): words
        case .thinking: "Working on it…"
        case .confirming(let question): question
        case .pausedForDictation: "Paused while dictating"
        case .unavailable(let reason): reason
        }
    }

    private var accessibilityTitle: String {
        if case .hearing = agent.status { return "Listening" }
        return title
    }

    /// The last reply, under the status, except when the status already says it.
    private var detail: String? {
        switch agent.status {
        case .needsKey, .unavailable, .confirming: nil
        default: agent.lastReply
        }
    }
}
