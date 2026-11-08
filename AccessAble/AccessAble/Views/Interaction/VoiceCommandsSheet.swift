import SwiftUI

/// Owner: User Interaction (3.1). Opened by the Info button: what you can say.
/// On the trip screen, `onTry` lets each command be tried by tapping it.
struct VoiceCommandsSheet: View {
    var onTry: ((VoiceCommandHint) -> Void)?
    var onSimulateBlockedRoute: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Voice Commands")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    CircleIconButton(systemImage: "xmark", label: "Close", diameter: 44) { dismiss() }
                }
                Text(onTry == nil
                     ? "Unmute the microphone during a trip and say any of these."
                     : "Unmute the microphone and say any of these, or tap one to try it.")
                    .font(.body)

                ForEach(VoiceCommandHint.allCases) { command in
                    commandRow(command)
                }

                if let onSimulateBlockedRoute {
                    Text("Preview")
                        .font(.title3.weight(.semibold))
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    Button("Show a blocked route alert", action: onSimulateBlockedRoute)
                        .buttonStyle(.pill(.outline))
                }
            }
            .foregroundStyle(.white)
            .padding(24)
        }
        .background(Color.black.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func commandRow(_ command: VoiceCommandHint) -> some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            Text("\u{201C}\(command.phrase)\u{201D}")
                .font(.title3.weight(.semibold))
            Text(command.summary)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

        if let onTry {
            Button { onTry(command) } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityHint("Tries this command now")
        } else {
            content.accessibilityElement(children: .combine)
        }
    }
}

#Preview {
    Color.black.sheet(isPresented: .constant(true)) {
        VoiceCommandsSheet(onTry: { _ in }, onSimulateBlockedRoute: {})
    }
}
