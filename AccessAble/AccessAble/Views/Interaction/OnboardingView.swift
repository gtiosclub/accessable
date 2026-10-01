import SwiftUI

/// Owner: User Interaction (3.4). Minimal survey — extend with the tutorial, Practice mode, and permissions.
struct OnboardingView: View {
    @Environment(AppViewModel.self) private var app
    @State private var viewModel = OnboardingViewModel()

    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationStack {
            Form {
                Section("How do you want to use AccessAble?") {
                    Picker("Vision", selection: $viewModel.visionLevel) {
                        ForEach(VisionLevel.allCases, id: \.self) { Text($0.displayName) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Safety") {
                    Text(OnboardingViewModel.safetyDisclosure)
                    Toggle("I understand", isOn: $viewModel.hasAcknowledgedSafetyDisclosure)
                }

                Section {
                    Button("Get started") {
                        app.completeOnboarding(with: viewModel.profile)
                    }
                    .disabled(!viewModel.canFinish)
                    .accessibilityHint(viewModel.canFinish ? "" : "Confirm the safety notice first")
                }
            }
            .navigationTitle("Welcome")
        }
    }
}

#Preview {
    OnboardingView()
        .environment(AppViewModel(defaults: UserDefaults(suiteName: "preview-onboarding") ?? .standard))
}
