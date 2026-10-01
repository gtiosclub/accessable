import SwiftUI

/// Owner: Maps + Location (2.x). Placeholder UI — add search, route preview, and the map here.
struct TripView: View {
    @State private var viewModel: TripViewModel

    init(services: AppServices) {
        _viewModel = State(initialValue: TripViewModel(services: services))
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(viewModel.nextInstruction)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.updatesFrequently)

            if viewModel.tripState.phase == .active || viewModel.tripState.phase == .paused {
                AccessibleActionButton(
                    title: viewModel.tripState.phase == .paused ? "Resume trip" : "Pause trip",
                    systemImage: viewModel.tripState.phase == .paused ? "play.fill" : "pause.fill",
                    hint: "Pauses or resumes navigation announcements"
                ) {
                    Task { await viewModel.togglePause() }
                }

                AccessibleActionButton(
                    title: "End trip", systemImage: "xmark", hint: "Stops navigation", role: .destructive
                ) {
                    Task { await viewModel.endTrip() }
                }
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Trip")
        .task { await viewModel.start() }
    }
}

#Preview {
    NavigationStack {
        TripView(services: .preview)
    }
}
