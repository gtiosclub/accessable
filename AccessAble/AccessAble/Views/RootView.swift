import SwiftUI

/// Decides between onboarding and the main app.
struct RootView: View {
    @Environment(AppViewModel.self) private var app

    var body: some View {
        if app.hasCompletedOnboarding {
            NavigationStack {
                HomeView(services: app.services)
            }
        } else {
            OnboardingView()
        }
    }
}

#Preview {
    RootView()
        .environment(AppViewModel.preview)
}
