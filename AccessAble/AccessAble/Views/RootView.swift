import SwiftUI

/// Decides between onboarding and the main app.
struct RootView: View {
    @Environment(AppViewModel.self) private var app
    @State private var path: [AppDestination] = []
    private let router = IntentsModel.shared

    var body: some View {
        if app.hasCompletedOnboarding {
            NavigationStack(path: $path) {
                HomeView(services: app.services)
                    .navigationDestination(for: AppDestination.self) { destination in
                        switch destination {
                        case .scene:
                            SceneView(services: app.services)
                        case .trip:
                            TripView(services: app.services)
                        }
                    }
            }
            .onChange(of: router.pending, initial: true) { _, destination in
                guard let destination else { return }
                path = [destination]
                router.pending = nil
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
