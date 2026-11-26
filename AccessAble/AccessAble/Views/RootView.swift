import SwiftUI

/// Decides between onboarding and the main app.
struct RootView: View {
    @Environment(AppViewModel.self) private var app

    var body: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-LiveKitMediaTest") {
                LiveKitMediaTestView(services: app.services)
            } else {
                appContent
            }
            #else
            appContent
            #endif
        }
        // The redesign is dark throughout; this also keeps the status bar light.
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var appContent: some View {
        if app.services.accountsAvailable { AccountGateView(services: app.services) }
        else if app.hasCompletedOnboarding { MainFlowView() }
        else { OnboardingView(includesAccount: false) }
    }
}

private struct AccountGateView: View {
    @Environment(AppViewModel.self) private var app
    @State private var session: AccountSessionViewModel
    @State private var signOutError: String?

    init(services: AppServices) {
        _session = State(initialValue: AccountSessionViewModel(
            auth: services.auth, profiles: services.userProfiles, presence: services.presence,
            savedTrips: services.savedTrips, trip: services.trip))
    }

    var body: some View {
        Group {
            switch session.state {
            case .loading:
                ProgressView("Loading your account")
            case .signedOut:
                SignInView(auth: app.services.auth)
            case .needsProfile(let user):
                OnboardingView(onSave: { role, name, languages in
                    try await session.saveProfile(role: role, displayName: name, languages: languages)
                }, onSignOut: { try await session.signOut() })
                .id(user.id)
            case .ready(let profile):
                if profile.role == .volunteer {
                    VolunteerCallHostView(profile: profile, services: app.services, signOut: { try await session.signOut() })
                        .id(profile.userID)
                } else if app.hasCompletedOnboarding {
                    MainFlowView().id(profile.userID)
                } else {
                    OnboardingView(includesAccount: false).id(profile.userID)
                }
            case .failed(let message):
                VStack(spacing: 20) {
                    Text(message).multilineTextAlignment(.center)
                    Button("Retry") { Task { await session.retry() } }
                        .frame(minHeight: 44)
                    Button("Sign out") {
                        Task {
                            do { try await session.signOut() }
                            catch { signOutError = "Couldn't sign out. Please try again." }
                        }
                    }.frame(minHeight: 44)
                }.padding()
            }
        }
        .task { await session.listen() }
        .alert("Account", isPresented: Binding(
            get: { signOutError != nil }, set: { if !$0 { signOutError = nil } }
        )) { Button("OK") { signOutError = nil } } message: {
            Text(signOutError ?? "")
        }
    }
}

/// Landing page and everything pushed from it.
struct MainFlowView: View {
    @Environment(AppViewModel.self) private var app
    @State private var router = AppRouter()
    @State private var resumeTrip: ResumeTripViewModel?
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
        .task {
            let resume = ResumeTripViewModel(store: app.services.savedTrips, trip: app.services.trip)
            resumeTrip = resume
            await resume.check()
        }
        .alert(
            resumeTrip?.title ?? "",
            isPresented: Binding(
                get: { resumeTrip?.offer != nil },
                // SwiftUI can close the alert before running a button's action, so closing isn't an answer
                set: { if !$0 { resumeTrip?.dismiss() } }
            ),
            presenting: resumeTrip?.offer
        ) { offer in
            Button("Resume trip") {
                guard let plan = resumeTrip?.resume(offer) else { return }
                router.path = [.trip(plan)]
            }
            Button("No thanks", role: .cancel) { resumeTrip?.decline() }
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
            PlaceDetailView(place: place, origin: origin, services: app.services)
        case .destination(let destination, let origin):
            PlaceDetailView(destination: destination, origin: origin, services: app.services)
        case .routes(let place, let mode, let origin, let planned):
            RoutePickerView(place: place, mode: mode, origin: origin, planned: planned, services: app.services)
        case .trip(let plan):
            ActiveTripView(plan: plan, services: app.services)
        case .settings:
            SettingsView(app: app)
        case .callHelp:
            CallHelpView()
        case .volunteers:
            VolunteerListView(services: app.services)
        case .call(let volunteer):
            CallFlowView(volunteer: volunteer)
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
