import SwiftUI

/// Owner: Maps. The route choices pushed from Settings; each is a preference, not a guarantee.
struct RoutePreferencesView: View {
    @State private var viewModel: RoutePreferencesViewModel

    init(store: RoutePreferencesStore) {
        _viewModel = State(initialValue: RoutePreferencesViewModel(store: store))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSectionTitle("Route preferences")
                VStack(spacing: 0) {
                    ForEach(Self.toggles, id: \.title) { toggle in
                        SettingsToggleRow(toggle.title, isOn: $viewModel.preferences[dynamicMember: toggle.keyPath])
                            .accessibilityHint("Routes \(toggle.effect) when there's another way. Takes effect on your next route.")
                    }
                    SettingsPickerRow("Walking speed", selection: $viewModel.preferences.walkingSpeed) {
                        Text("Slow").tag(RoutePreferences.WalkingSpeed.slow)
                        Text("Normal").tag(RoutePreferences.WalkingSpeed.normal)
                        Text("Fast").tag(RoutePreferences.WalkingSpeed.fast)
                    }
                    .accessibilityHint("Routes are timed for this pace, as an estimate. Takes effect on your next route.")
                }
                .padding(.leading, 8)

                Text("AccessAble can't yet avoid escalators, curbs or rough surfaces.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(SettingsPalette.background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .navigationTitle("Route preferences")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await viewModel.listen() }
    }

    private struct PreferenceToggle {
        let title: String
        let keyPath: WritableKeyPath<RoutePreferences, Bool>
        /// Completes "Routes … when there's another way."
        let effect: String
    }

    private static let toggles = [
        PreferenceToggle(title: "Avoid stairs", keyPath: \.avoidStairs, effect: "go around stairs"),
        PreferenceToggle(title: "Avoid elevators", keyPath: \.avoidElevators, effect: "go around elevators"),
        PreferenceToggle(title: "Avoid steep hills", keyPath: \.avoidSteepHills, effect: "go around steep hills"),
        PreferenceToggle(title: "Prefer well-lit paths", keyPath: \.preferWellLit, effect: "favor paths mapped as lit"),
        PreferenceToggle(title: "Prefer footpaths and sidewalks", keyPath: \.preferFootpaths,
               effect: "favor footpaths and sidewalks"),
        PreferenceToggle(title: "Avoid alleys and driveways", keyPath: \.avoidAlleysAndDriveways,
               effect: "go around alleys and driveways"),
        PreferenceToggle(title: "Avoid parking lots and service roads", keyPath: \.avoidServiceRoads,
               effect: "go around parking lots and service roads"),
        PreferenceToggle(title: "Avoid unpaved paths", keyPath: \.avoidUnpavedPaths, effect: "go around unpaved paths"),
    ]
}

#Preview {
    NavigationStack {
        RoutePreferencesView(store: AppServices.preview.routePreferences)
    }
}
