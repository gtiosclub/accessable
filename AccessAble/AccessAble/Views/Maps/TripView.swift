import MapKit
import SwiftUI

/// Owner: Maps + Location (2.x). Placeholder UI — add search and route preview here.
struct TripView: View {
    @State private var viewModel: TripViewModel
    @State private var cameraPosition: MapCameraPosition = .automatic

    init(services: AppServices) {
        _viewModel = State(initialValue: TripViewModel(services: services))
    }

    var body: some View {
        VStack(spacing: 16) {
            TripMapView(tripState: viewModel.tripState, cameraPosition: $cameraPosition)
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
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Trip")
        .task { await viewModel.start() }
    }
}

/// Shows the upcoming maneuver on a map. No live user-location dot yet — that needs a wired-up
/// `LocationProvider` (TODO(Maps 2.1)) plus an `NSLocationWhenInUseUsageDescription` entry.
private struct TripMapView: View {
    let tripState: TripState
    @Binding var cameraPosition: MapCameraPosition

    var body: some View {
        Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
            if let maneuver = tripState.nextManeuver {
                Marker(tripState.destinationName ?? maneuver.instruction,
                       systemImage: maneuver.kind.mapSymbolName,
                       coordinate: maneuver.coordinate.clCoordinate)
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onChange(of: tripState.nextManeuver) { _, maneuver in
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
            ),
            cameraPosition: .constant(
                .region(MKCoordinateRegion(center: MapsSamples.origin.clCoordinate,
                                            latitudinalMeters: 400, longitudinalMeters: 400))
            )
        )
        .navigationTitle("Trip")
    }
}
