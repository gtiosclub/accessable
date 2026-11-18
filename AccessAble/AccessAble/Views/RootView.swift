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
    @Environment(\.scenePhase) private var scenePhase
    @State private var router = AppRouter()
    @State private var agentRegistry = AgentControlRegistry()
    /// Made in `.task`, which runs once, so the view's init stays free of side effects.
    @State private var agent: VoiceAgentViewModel?
    private let intents = IntentsModel.shared

    var body: some View {
        @Bindable var router = router
        // Stacked rather than a safe-area inset: screens inside the NavigationStack don't see an
        // inset added outside it, and the bar would cover their bottom buttons.
        VStack(spacing: 0) {
            NavigationStack(path: $router.path) {
                LandingView()
                    .navigationDestination(for: AppRoute.self) { route in
                        destination(for: route)
                    }
            }
            if let agent {
                VoiceAgentBar(agent: agent) { router.push(.settings) }
                    .padding(.top, 4)
                    .background(Color.black.ignoresSafeArea(edges: .bottom))
            }
        }
        .environment(router)
        .environment(\.agentRegistry, agentRegistry)
        .task {
            guard agent == nil else { return }
            let agent = VoiceAgentViewModel(services: app.services, router: router, registry: agentRegistry)
            self.agent = agent
            await agent.start()
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await agent?.appActivityChanged(isActive: phase == .active) }
        }
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
            PlaceSearchView(services: app.services)
        case .place(let place, let origin):
            PlaceDetailView(place: place, origin: origin)
        case .routes(let place, let mode, let origin):
            RoutePickerView(place: place, mode: mode, origin: origin)
        case .trip(let plan):
            ActiveTripView(plan: plan, services: app.services)
        case .settings:
            SettingsView(app: app)
                // Changing a setting by voice asks first.
                .environment(\.agentActionsNeedConfirmation, true)
        case .callHelp:
            CallHelpView()
        case .chat(let volunteer):
            VolunteerChatView(volunteer: volunteer)
        case .developerTools:
            DeveloperToolsView()
        case .feature(.scene):
            LiveSceneView(services: app.services, mode: .walk)
        case .feature(.trip):
            TripView(services: app.services)
        }
    }
}

#Preview {
    RootView()
        .environment(AppViewModel.preview)
}
