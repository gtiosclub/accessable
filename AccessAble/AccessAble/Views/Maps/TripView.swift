import SwiftUI

/// Owner: Maps + Location (2.x). Placeholder UI — add search, route preview, and the map here.
struct TripView: View {
    @State private var viewModel: TripViewModel
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
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
            } else {
                if let destination = viewModel.destination {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Destination")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(destination.name)
                            .font(.title3.weight(.semibold))
                        if let address = destination.address {
                            Text(address)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }

                NavigationLink {
                    DestinationSearchView(services: services) { viewModel.setDestination($0) }
                } label: {
                    Label(viewModel.destination == nil ? "Choose destination" : "Change destination", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                        .padding(.horizontal)
                }
                .buttonStyle(.bordered)
                .font(.title3)
                .accessibilityHint("Search for a place or address to walk to")
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
