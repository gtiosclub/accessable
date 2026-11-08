import SwiftUI

/// Decides between onboarding and the main app.
struct RootView: View {
    @Environment(AppViewModel.self) private var app

    var body: some View {
        Group {
            if app.hasCompletedOnboarding {
                MainFlowView()
            } else {
                OnboardingView()
            }
        }
        // The redesign is dark throughout; this also keeps the status bar light.
        .preferredColorScheme(.dark)
    }
}

/// Landing page and everything pushed from it.
struct MainFlowView: View {
    @Environment(AppViewModel.self) private var app
    @State private var router = AppRouter()
    private let intents = IntentsModel.shared

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            LandingView()
                .navigationDestination(for: AppRoute.self) { route in
                    destination(for: route)
                }
        }
        .environment(router)
        .onChange(of: intents.pending, initial: true) { _, destination in
            guard let destination else { return }
            router.path = [.feature(destination)]
            intents.pending = nil
        }
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .search:
            PlaceSearchView()
        case .place(let place):
            PlaceDetailView(place: place)
        case .routes(let place, let mode):
            RoutePickerView(place: place, mode: mode)
        case .trip(let plan):
            ActiveTripView(plan: plan)
        case .settings:
            SettingsView(app: app)
        case .callHelp:
            CallHelpView()
        case .chat(let volunteer):
            VolunteerChatView(volunteer: volunteer)
        case .developerTools:
            DeveloperToolsView()
        case .feature(.scene):
            SceneView(services: app.services)
        case .feature(.trip):
            TripView(services: app.services)
        }
    }
}

#Preview {
    RootView()
        .environment(AppViewModel.preview)
}
