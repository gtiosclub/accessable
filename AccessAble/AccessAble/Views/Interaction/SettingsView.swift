import SwiftUI

/// Owner: User Interaction (3.3 / 3.4). Every GuidanceProfile field is editable here,
/// along with the settings-page preferences in `SettingsPreferences`.
struct SettingsView: View {
    @State private var viewModel: SettingsViewModel
    @State private var isConfirmingReset = false
    @Environment(\.dismiss) private var dismiss

    init(app: AppViewModel) {
        _viewModel = State(initialValue: SettingsViewModel(app: app))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                SettingsSectionTitle("Basics")
                VStack(spacing: 0) {
                    SettingsToggleRow("Haptics", isOn: channelBinding(.haptics))
                    SettingsToggleRow("Speech Sounds", isOn: channelBinding(.speech))
                    SettingsToggleRow("Phone Aiming Help", isOn: $viewModel.preferences.phoneAimingHelp)
                    SettingsToggleRow("Use Metric for Distance", isOn: $viewModel.preferences.usesMetricUnits)
                }
                .padding(.leading, 8)

                SettingsSectionTitle("Navigation Info Output")
                SettingsCard("Auto Repeat Announcements") {
                    ForEach(AutoRepeat.allCases, id: \.self) { option in
                        SettingsOptionRow(
                            option.displayName,
                            isSelected: viewModel.preferences.autoRepeat == option
                        ) {
                            viewModel.preferences.autoRepeat = option
                        }
                    }
                }
                topicCard("Prioritized information", list: .prioritized, options: Self.prioritizedOptions)

                SettingsSectionTitle("Prompted VS. Unprompted Info")
                topicCard("Unprompted Announcements", list: .unprompted, options: Self.allTopicOptions)
                topicCard("Prompted Announcements", list: .prompted, options: Self.allTopicOptions)

                SettingsSectionTitle("Advanced")
                VStack(spacing: 0) {
                    SettingsToggleRow("System Screen Reader", isOn: $viewModel.preferences.usesSystemScreenReader)
                    SettingsToggleRow("Quick Settings", isOn: $viewModel.preferences.quickSettingsEnabled)
                    SettingsToggleRow("Spatial Audio", isOn: channelBinding(.spatialAudio))
                    profileControls
                }
                .padding(.leading, 8)

                SettingsCard("Announcement Types") {
                    ForEach(AnnouncementCategory.allCases, id: \.self) { category in
                        SettingsOptionRow(
                            category.rawValue.capitalized,
                            isSelected: viewModel.isEnabled(category)
                        ) {
                            viewModel.setCategory(category, enabled: !viewModel.isEnabled(category))
                        }
                    }
                }

                resetCard

                NavigationLink {
                    DeveloperToolsView()
                } label: {
                    HStack {
                        Text("Developer Tools")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .accessibilityHidden(true)
                    }
                    .font(.body)
                    .foregroundStyle(.white)
                    .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .accessibilityHint("Camera guidance, live detection, and trip screens for testing")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(SettingsPalette.background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .toolbar(.hidden, for: .navigationBar)
        // VoiceOver two-finger scrub, since the back button is replaced by the Done button.
        .accessibilityAction(.escape) { dismiss() }
        .confirmationDialog(
            "Reset all settings to their defaults?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                viewModel.resetToDefaults()
                AccessibilityNotification.Announcement("Settings reset to defaults").post()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center) {
            Text("Set Preferences")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            Button {
                dismiss()
            } label: {
                Image(systemName: "checkmark")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(SettingsPalette.done))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done")
            .accessibilityHint("Closes settings. Changes are already saved.")
        }
        .padding(.top, 8)
    }

    /// Controls for profile fields the mockup doesn't cover.
    @ViewBuilder
    private var profileControls: some View {
        @Bindable var viewModel = viewModel
        SettingsPickerRow("Vision Preset", selection: Binding(
            get: { viewModel.profile.visionLevel },
            set: { viewModel.applyPreset($0) }
        )) {
            ForEach(VisionLevel.allCases, id: \.self) { Text($0.displayName) }
        }
        SettingsPickerRow("Announcement Detail", selection: $viewModel.profile.verbosity) {
            Text("Important only").tag(Verbosity.passive)
            Text("Everything").tag(Verbosity.active)
        }
        SettingsSliderRow("Speech Rate", value: $viewModel.profile.speechRate, in: 0.3...0.7)
        SettingsSliderRow("Haptic Strength", value: $viewModel.profile.hapticIntensity, in: 0...1)
        SettingsPickerRow(
            "Performance",
            selection: $viewModel.performanceSetting,
            footnote: "Currently \(viewModel.currentPerformanceMode == .battery ? "saving battery" : "using best quality")"
        ) {
            Text("Automatic").tag(PerformanceModeSetting.automatic)
            Text("Best quality").tag(PerformanceModeSetting.normal)
            Text("Save battery").tag(PerformanceModeSetting.battery)
        }
    }

    private var resetCard: some View {
        Button {
            isConfirmingReset = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reset to Default Settings")
                        .font(.subheadline.bold())
                    Text("Restores every setting on this page to its original value.")
                        .font(.footnote)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "arrow.counterclockwise")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(SettingsPalette.accent)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: AccessibilityMetrics.minimumTapTarget)
            .settingsCardBackground()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Asks before resetting")
    }

    private func topicCard(_ title: String, list: InfoTopicList, options: [TopicOption]) -> some View {
        SettingsCard(title) {
            ForEach(options) { option in
                SettingsOptionRow(option.label, isSelected: viewModel.isSelected(option.topic, in: list)) {
                    viewModel.toggle(option.topic, in: list)
                }
            }
        }
    }

    private func channelBinding(_ channel: GuidanceChannels) -> Binding<Bool> {
        Binding(
            get: { viewModel.isEnabled(channel) },
            set: { viewModel.setChannel(channel, enabled: $0) }
        )
    }

    private struct TopicOption: Identifiable {
        let topic: InfoTopic
        var label: String

        init(_ topic: InfoTopic, label: String? = nil) {
            self.topic = topic
            self.label = label ?? topic.displayName
        }

        var id: InfoTopic { topic }
    }

    private static let allTopicOptions = InfoTopic.allCases.map { TopicOption($0) }

    private static let prioritizedOptions = [
        TopicOption(.detailedDescription),
        TopicOption(.trafficAndCrowds),
        TopicOption(.openingsAndObstacles),
        TopicOption(.signsAndText, label: "Recognized signs/texts in view"),
    ]
}

// MARK: - Styling

private enum SettingsPalette {
    static let background = Color(red: 0.11, green: 0.16, blue: 0.23)
    static let card = Color(white: 0.29)
    static let done = Color(red: 0.22, green: 0.55, blue: 0.24)
    /// Lighter than system blue so checkmarks keep 3:1 contrast on the gray cards.
    static let accent = Color(red: 0.40, green: 0.66, blue: 1.0)
    static let rowSeparator = Color.white.opacity(0.22)
    static let cardSeparator = Color.white.opacity(0.35)
}

private extension View {
    func settingsCardBackground() -> some View {
        background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white, lineWidth: 1.5)
            )
    }
}

private struct SettingsSectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.title3)
            .foregroundStyle(.white)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A plain row on the page background with a hairline under it.
private struct SettingsRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, minHeight: AccessibilityMetrics.minimumTapTarget, alignment: .leading)
                .padding(.vertical, 4)
            Rectangle()
                .fill(SettingsPalette.rowSeparator)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        SettingsRow {
            Toggle(title, isOn: $isOn)
                .font(.body)
                .foregroundStyle(.white)
                .tint(SettingsPalette.accent)
        }
    }
}

private struct SettingsPickerRow<Value: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Value
    var footnote: String?
    @ViewBuilder let options: Options

    init(_ title: String, selection: Binding<Value>, footnote: String? = nil, @ViewBuilder options: () -> Options) {
        self.title = title
        _selection = selection
        self.footnote = footnote
        self.options = options()
    }

    var body: some View {
        SettingsRow {
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent {
                    Picker(title, selection: $selection) { options }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .tint(SettingsPalette.accent)
                } label: {
                    Text(title).foregroundStyle(.white)
                }
                if let footnote {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
    }
}

private struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>

    init(_ title: String, value: Binding<Float>, in range: ClosedRange<Float>) {
        self.title = title
        _value = value
        self.range = range
    }

    var body: some View {
        SettingsRow {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
                Slider(value: $value, in: range) { Text(title) }
                    .tint(SettingsPalette.accent)
            }
        }
    }
}

/// A rounded, outlined card with a bold title and a list of rows separated by hairlines.
private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .padding(.vertical, 12)
                .accessibilityAddTraits(.isHeader)
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    Rectangle()
                        .fill(SettingsPalette.cardSeparator)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                    row
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCardBackground()
        .accessibilityElement(children: .contain)
    }
}

/// A selectable row inside a card: label on the left, checkmark on the right when selected.
private struct SettingsOptionRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    init(_ title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(SettingsPalette.accent)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: AccessibilityMetrics.minimumTapTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    NavigationStack {
        SettingsView(app: .preview)
    }
}
