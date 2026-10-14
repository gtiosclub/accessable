import MapKit
import SwiftUI

/// Owner: Maps + Location (2.x). Trip planning and active-trip screen.
struct TripView: View {
    @State private var viewModel: TripViewModel
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
        _viewModel = State(initialValue: TripViewModel(services: services))
    }

    var body: some View {
        VStack(spacing: 16) {
            TripMapView(tripState: viewModel.tripState)
                .frame(minHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

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

/// Shows the upcoming maneuver on a map. The user-location dot comes with MAP-5.
private struct TripMapView: View {
    let tripState: TripState
    // .automatic zooms out to the whole continent when there's nothing on the map yet
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(center: SearchRegion.georgiaTech.center.clCoordinate,
                           latitudinalMeters: 1_500, longitudinalMeters: 1_500)
    )

    var body: some View {
        Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
            if let maneuver = tripState.nextManeuver {
                Marker(maneuver.instruction,
                       systemImage: maneuver.kind.mapSymbolName,
                       coordinate: maneuver.coordinate.clCoordinate)
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onChange(of: tripState.nextManeuver, initial: true) { _, maneuver in
            guard let maneuver else { return }
            withAnimation {
                cameraPosition = .region(
                    MKCoordinateRegion(
                        center: maneuver.coordinate.clCoordinate,
                        latitudinalMeters: 300,
                        longitudinalMeters: 300
                    )
                )
            }
        }
        // The spoken instruction above already conveys maneuver details; expose the map as one
        // summary element so VoiceOver users can swipe past it instead of exploring each pin.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mapAccessibilityLabel)
    }

    private var mapAccessibilityLabel: String {
        guard let destinationName = tripState.destinationName else { return "Map" }
        return "Map showing route to \(destinationName)"
    }
}

private extension ManeuverKind {
    var mapSymbolName: String {
        switch self {
        case .depart: "figure.walk.departure"
        case .straight: "arrow.up"
        case .turnLeft, .slightLeft: "arrow.turn.up.left"
        case .turnRight, .slightRight: "arrow.turn.up.right"
        case .uTurn: "arrow.uturn.up"
        case .cross: "figure.walk"
        case .arrive: "mappin.and.ellipse"
        }
    }
}

#Preview {
    NavigationStack {
        TripView(services: .preview)
    }
}

#Preview("With a planned trip") {
    NavigationStack {
        TripMapView(
            tripState: TripState(
                phase: .active,
                destinationName: MapsSamples.destination.name,
                nextManeuver: Maneuver(
                    kind: .turnLeft,
                    instruction: "Turn left onto the campus walkway",
                    coordinate: MapsSamples.destination.coordinate
                ),
                distanceToNextManeuver: 42,
                distanceRemaining: 111
            )
        )
        .navigationTitle("Trip")
    }
}
