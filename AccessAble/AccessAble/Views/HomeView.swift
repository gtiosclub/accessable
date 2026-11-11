import SwiftUI

/// Template for every screen in the app:
/// - the view owns its view model with `@State`, created from injected `AppServices`
/// - `.task { await viewModel.start() }` starts subscriptions and cancels them on disappear
/// - no business logic in the view; buttons call view model functions
struct HomeView: View {
    @State private var viewModel: HomeViewModel
    @Environment(AppViewModel.self) private var app
    private let intents = IntentsModel.shared

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

                // One camera screen, opened in the mode the button names (Walk, Find, Read,
                // Describe are switched at its top).
                NavigationLink {
                    LiveSceneView(services: app.services, mode: .walk)
                } label: {
                    Label("Camera guidance", systemImage: "camera.viewfinder")
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .padding(.horizontal)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Announces obstacles as you walk. Also finds places, reads signs and describes what is around you.")

                NavigationLink {
                    LiveSceneView(services: app.services, mode: .read)
                } label: {
                    Label("Read signs & text", systemImage: "text.viewfinder")
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .padding(.horizontal)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Announces signs and text as the camera finds them")

                NavigationLink {
                    TripView(services: app.services)
                } label: {
                    Label("Trip", systemImage: "figure.walk")
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .padding(.horizontal)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Plan or continue a walking trip")
                
                NavigationLink {
                    CommandView(services: app.services)
                } label: {
                    Label("Commands", systemImage: "text.bubble")
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .padding(.horizontal)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Type a command or ask a question")
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
        // Two-finger double-tap under VoiceOver
        .accessibilityAction(.magicTap) {
            Task { await viewModel.repeatLast() }
        }
        .onChange(of: intents.describeRequested, initial: true) { _, requested in
            guard requested else { return }
            intents.describeRequested = false
            Task { await viewModel.describeSurroundings() }
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
