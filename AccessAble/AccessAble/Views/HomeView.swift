import SwiftUI

/// Template for every screen in the app:
/// - the view owns its view model with `@State`, created from injected `AppServices`
/// - `.task { await viewModel.start() }` starts subscriptions and cancels them on disappear
/// - no business logic in the view; buttons call view model functions
struct HomeView: View {
    @State private var viewModel: HomeViewModel
    @Environment(AppViewModel.self) private var app

    init(services: AppServices) {
        _viewModel = State(initialValue: HomeViewModel(services: services))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let event = viewModel.lastAnnouncement {
                    AnnouncementBanner(event: event)
                }

                AccessibleActionButton(
                    title: "Describe my surroundings",
                    systemImage: "eye",
                    hint: "Speaks what the camera sees, nearest hazards first"
                ) {
                    Task { await viewModel.describeSurroundings() }
                }
                .disabled(viewModel.isDescribing)

                NavigationLink {
                    SceneView(services: app.services)
                } label: {
                    Label("Camera guidance", systemImage: "camera.viewfinder")
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .padding(.horizontal)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Announces obstacles as you walk")

                NavigationLink {
                    LiveSceneView(services: app.services)
                } label: {
                    Label("Live detection", systemImage: "viewfinder.rectangular")
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .padding(.horizontal)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Shows what the camera detects right now. Needs a LiDAR device.")

                NavigationLink {
                    TripView(services: app.services)
                } label: {
                    Label("Trip", systemImage: "figure.walk")
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .padding(.horizontal)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Plan or continue a walking trip")
            }
            .font(.title3)
            .padding()
        }
        .navigationTitle("AccessAble")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView(app: app)
                } label: {
                    Image(systemName: "gearshape")
                        .minimumTapTarget()
                }
                .accessibilityLabel("Settings")
            }
        }
        // Two-finger double-tap under VoiceOver.
        .accessibilityAction(.magicTap) {
            Task { await viewModel.repeatLast() }
        }
        .task { await viewModel.start() }
    }
}

#Preview {
    let app = AppViewModel.preview
    NavigationStack {
        HomeView(services: app.services)
    }
    .environment(app)
}
