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

            Section("Channels") {
                channelToggle("Speech", .speech)
                channelToggle("Haptics", .haptics)
                channelToggle("Spatial audio", .spatialAudio)
                LabeledContent("Speech rate") {
                    Slider(value: $viewModel.profile.speechRate, in: 0.3...0.7)
                }
                LabeledContent("Haptic intensity") {
                    Slider(value: $viewModel.profile.hapticIntensity, in: 0...1)
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
                Picker("Performance", selection: $viewModel.performanceSetting) {
                    Text("Automatic").tag(PerformanceModeSetting.automatic)
                    Text("Best quality").tag(PerformanceModeSetting.normal)
                    Text("Save battery").tag(PerformanceModeSetting.battery)
                }
            } footer: {
                Text("Currently: \(viewModel.currentPerformanceMode == .battery ? "saving battery" : "best quality")")
            }
        }
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
