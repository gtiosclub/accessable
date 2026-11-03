import SwiftUI

/// Owner: User Interaction (3.3 / 3.4). Every GuidanceProfile field is editable here.
struct SettingsView: View {
    @State private var viewModel: SettingsViewModel

    init(app: AppViewModel) {
        _viewModel = State(initialValue: SettingsViewModel(app: app))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        Form {
            Section("Profile") {
                Picker("Vision", selection: Binding(
                    get: { viewModel.profile.visionLevel },
                    set: { viewModel.applyPreset($0) }
                )) {
                    ForEach(VisionLevel.allCases, id: \.self) { Text($0.displayName) }
                }
                Picker("Verbosity", selection: $viewModel.profile.verbosity) {
                    Text("Passive — important only").tag(Verbosity.passive)
                    Text("Active — everything").tag(Verbosity.active)
                }
            }

            Section("Announcements") {
                ForEach(AnnouncementCategory.allCases, id: \.self) { category in
                    Toggle(category.rawValue.capitalized, isOn: Binding(
                        get: { viewModel.isEnabled(category) },
                        set: { viewModel.setCategory(category, enabled: $0) }
                    ))
                }
            }

            Section {
                let order = viewModel.profile.aiPriorities.order
                ForEach(Array(order.enumerated()), id: \.element) { index, category in
                    Text("\(index + 1). \(category.displayName)")
                        // VoiceOver can't drag, so it moves rows with the rotor's Actions.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(category.displayName)
                        .accessibilityValue("\(index + 1) of \(order.count)")
                        .accessibilityAction(named: "Move up") { viewModel.moveAIPriority(category, by: -1) }
                        .accessibilityAction(named: "Move down") { viewModel.moveAIPriority(category, by: 1) }
                }
                .onMove { viewModel.moveAIPriorities(from: $0, to: $1) }
            } header: {
                Text("Ask AI — mention first")
            } footer: {
                Text("Drag the handles to reorder. Ask AI answers in this order. Hazards close ahead are always mentioned first.")
            }

            Section {
                channelToggle("Speech", .speech)
                channelToggle("Haptics", .haptics)
                channelToggle("Spatial audio", .spatialAudio)
                LabeledContent("Speech rate") {
                    Slider(value: $viewModel.profile.speechRate, in: 0.3...0.7)
                }
                LabeledContent("Haptic intensity") {
                    Slider(value: $viewModel.profile.hapticIntensity, in: 0...1)
                }
            } header: {
                Text("Channels")
            } footer: {
                Text("When VoiceOver is on, announcements use it for speech.")
            }

            Section {
                Picker("Performance", selection: $viewModel.performanceSetting) {
                    Text("Automatic").tag(PerformanceModeSetting.automatic)
                    Text("Best quality").tag(PerformanceModeSetting.normal)
                    Text("Save battery").tag(PerformanceModeSetting.battery)
                }
            } footer: {
                Text("Currently: \(viewModel.currentPerformanceMode == .battery ? "saving battery" : "best quality")")
            }
        }
        // Edit mode is what shows the Ask AI drag handles. Only those rows can move or delete;
        // toggles and pickers behave as usual.
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Settings")
    }

    private func channelToggle(_ title: LocalizedStringKey, _ channel: GuidanceChannels) -> some View {
        Toggle(title, isOn: Binding(
            get: { viewModel.isEnabled(channel) },
            set: { viewModel.setChannel(channel, enabled: $0) }
        ))
    }
}

#Preview {
    NavigationStack {
        SettingsView(app: .preview)
    }
}
