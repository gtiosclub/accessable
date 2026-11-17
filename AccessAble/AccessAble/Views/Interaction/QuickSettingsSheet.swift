import SwiftUI

/// Owner: User Interaction (3.3 / task T51). A fast, frequently-used subset of Settings,
/// opened from the landing page without leaving it. Edits the same `SettingsViewModel`
/// Settings itself uses — nothing here can drift from the full page, because there's only
/// one source of truth underneath both. Only reachable when the user has left "Quick
/// Settings" enabled on the Settings page.
struct QuickSettingsSheet: View {
    @State private var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    init(app: AppViewModel) {
        _viewModel = State(initialValue: SettingsViewModel(app: app))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Quick Settings")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    CircleIconButton(systemImage: "xmark", label: "Close", diameter: 44) { dismiss() }
                }

                channelRow("Haptics", systemImage: "iphone.radiowaves.left.and.right", channel: .haptics)
                channelRow("Speech Sounds", systemImage: "speaker.wave.2.fill", channel: .speech)
                channelRow("Spatial Audio", systemImage: "airpods", channel: .spatialAudio)
                segmentedRow("Auto Repeat Announcements", selection: $viewModel.preferences.autoRepeat) {
                    ForEach(AutoRepeat.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                segmentedRow("Performance", selection: $viewModel.performanceSetting) {
                    Text("Automatic").tag(PerformanceModeSetting.automatic)
                    Text("Best quality").tag(PerformanceModeSetting.normal)
                    Text("Save battery").tag(PerformanceModeSetting.battery)
                }

                Text("For everything else, open Settings from the landing page.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(24)
        }
        .background(Color.black.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func channelRow(_ title: String, systemImage: String, channel: GuidanceChannels) -> some View {
        Toggle(isOn: channelBinding(channel)) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
        }
        .tint(Theme.cyan)
        .padding(16)
        .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func segmentedRow<Value: Hashable, Options: View>(
        _ title: String, selection: Binding<Value>, @ViewBuilder options: () -> Options
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            Picker(title, selection: selection) { options() }
                .pickerStyle(.segmented)
                .labelsHidden()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func channelBinding(_ channel: GuidanceChannels) -> Binding<Bool> {
        Binding(
            get: { viewModel.isEnabled(channel) },
            set: { viewModel.setChannel(channel, enabled: $0) }
        )
    }
}

#Preview {
    Color.black.sheet(isPresented: .constant(true)) {
        QuickSettingsSheet(app: .preview)
    }
}
