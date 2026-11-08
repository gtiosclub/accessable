import SwiftUI

/// Owner: Haptics (3.2). Plays each pattern in the haptic vocabulary at the user's
/// Haptic Strength setting, so the team can feel them without walking a route.
struct HapticsPracticeView: View {
    let services: AppServices
    @Environment(AppViewModel.self) private var app
    @State private var playing: HapticID?

    var body: some View {
        List {
            Section {
                ForEach(HapticID.allCases, id: \.self) { id in
                    row(for: id)
                }
            } footer: {
                Text("Plays at your Haptic Strength setting (\(app.profile.hapticIntensity, format: .percent.precision(.fractionLength(0)))). Needs an iPhone; the Simulator has no haptics.")
            }

            Section {
                Button("Stop", systemImage: "stop.fill", role: .destructive) {
                    Task { await stop() }
                }
                .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
                .disabled(playing == nil)
            }
        }
        .navigationTitle("Haptic Patterns")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onDisappear {
            Task { await services.haptics.stop() }
        }
    }

    private func row(for id: HapticID) -> some View {
        let hasPattern = id.ahapURL != nil
        return Button {
            Task { await play(id) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(id.displayName)
                        .font(.headline)
                    Text(hasPattern ? id.patternDescription : "No pattern file yet (\(id.ahapFileName).ahap)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if hasPattern, id.loopPeriod != nil {
                        Text("Repeats until stopped")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: playing == id ? "waveform" : "play.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasPattern)
        .accessibilityValue(playing == id ? "Playing" : "")
        .accessibilityHint(hasPattern ? "Plays this pattern" : "")
    }

    private func play(_ id: HapticID) async {
        playing = id
        await services.haptics.play(id, intensity: app.profile.hapticIntensity)
        // One-shot patterns are short; clear the indicator once they've had time to finish.
        guard id.loopPeriod == nil else { return }
        try? await Task.sleep(for: .seconds(1.5))
        if playing == id { playing = nil }
    }

    private func stop() async {
        await services.haptics.stop()
        playing = nil
    }
}

#Preview {
    let app = AppViewModel.preview
    NavigationStack {
        HapticsPracticeView(services: app.services)
    }
    .environment(app)
    .preferredColorScheme(.dark)
}
