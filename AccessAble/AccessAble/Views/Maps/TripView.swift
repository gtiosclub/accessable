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
        // scrolls so the notice and large text sizes push content down instead of under the title
        ScrollView {
            VStack(spacing: 16) {
                if viewModel.needsLocationAccess {
                    LocationAccessNotice(authorization: viewModel.locationAuthorization)
                }
                TripMapView(
                    tripState: viewModel.tripState,
                    destination: viewModel.destination,
                    route: viewModel.route,
                    showsUserLocation: viewModel.showsUserLocation,
                    accessibilityLabel: viewModel.mapAccessibilityLabel
                )
                    // a map has no natural height inside a scroll view
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text(viewModel.nextInstruction)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.updatesFrequently)

                if let message = viewModel.routeErrorMessage {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            // the map above would otherwise squeeze this to a truncated line at large text sizes
                            .fixedSize(horizontal: false, vertical: true)

                        AccessibleActionButton(
                            title: "Try again",
                            systemImage: "arrow.clockwise",
                            hint: "Asks for a walking route again"
                        ) {
                            viewModel.retryRoute()
                            // the button disappears from under VoiceOver focus, so say that something is happening
                            AccessibilityNotification.Announcement("Finding a walking route.").post()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(
                        Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                }

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
                        Label(
                            viewModel.destination == nil ? "Choose destination" : "Change destination",
                            systemImage: "magnifyingglass"
                        )
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                            .padding(.horizontal)
                    }
                    .buttonStyle(.bordered)
                    .font(.title3)
                    .accessibilityHint("Search for a place or address to walk to")
                }
            }
            .padding()
        }
        .navigationTitle("Trip")
        // VoiceOver doesn't read changes outside the focused element, so say the failure out loud
        .onChange(of: viewModel.routeFailureCount) {
            guard let message = viewModel.routeErrorMessage else { return }
            AccessibilityNotification.Announcement(message).post()
        }
        .task { await viewModel.start() }
    }
}

/// Shows the route, destination, upcoming maneuver, and the user's location when permission allows.
private struct TripMapView: View {
    let tripState: TripState
    let destination: Destination?
    let route: NavigationRoute?
    let showsUserLocation: Bool
    let accessibilityLabel: String
    @Environment(\.colorSchemeContrast) private var contrast
    // .automatic zooms out to the whole continent when there's nothing on the map yet
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(center: SearchRegion.georgiaTech.center.clCoordinate,
                           latitudinalMeters: 1_500, longitudinalMeters: 1_500)
    )

    var body: some View {
        Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
            if let route {
                let coordinates = route.coordinates.map(\.clCoordinate)
                // a background-coloured casing keeps the line visible over roads and parks of any colour
                MapPolyline(coordinates: coordinates)
                    .stroke(Color(.systemBackground), style: routeStroke(width: routeWidth + 4))
                MapPolyline(coordinates: coordinates)
                    .stroke(Self.routeColor, style: routeStroke(width: routeWidth))
            }
            // the destination marker already marks where the arrive maneuver is
            if let maneuver = tripState.nextManeuver, !(maneuver.kind == .arrive && destination != nil) {
                Marker(maneuver.instruction,
                       systemImage: maneuver.kind.mapSymbolName,
                       coordinate: maneuver.coordinate.clCoordinate)
            }
            if let destination {
                Marker(destination.name, systemImage: "flag.checkered", coordinate: destination.coordinate.clCoordinate)
            }
            if showsUserLocation {
                UserAnnotation()
            }
        }
        // muted map without points of interest so the route and markers are the boldest things on it
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onChange(of: route, initial: true) { _, route in
            guard let route else { return }
            withAnimation {
                cameraPosition = .rect(route.cameraRect())
            }
        }
        // without a route (no location yet, or no permission) the destination could be off screen
        .onChange(of: destination, initial: true) { _, destination in
            guard route == nil, let destination else { return }
            withAnimation {
                cameraPosition = .region(
                    MKCoordinateRegion(center: destination.coordinate.clCoordinate,
                                       latitudinalMeters: 500, longitudinalMeters: 500)
                )
            }
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
        .accessibilityLabel(accessibilityLabel)
    }

    // standard system blue measures under 3:1 against parts of the muted map; its Increase Contrast variant doesn't
    private static let routeColor = Color(UIColor { traits in
        UIColor.systemBlue.resolvedColor(with: traits.modifyingTraits { $0.accessibilityContrast = .high })
    })

    /// Points; thicker when Increase Contrast is on.
    private var routeWidth: CGFloat { contrast == .increased ? 10 : 7 }

    private func routeStroke(width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
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
            destination: MapsSamples.destination,
            route: MapsSamples.route,
            showsUserLocation: false,
            accessibilityLabel: "Map showing a walking route to Sample entrance, about 110 metres, about 1 minute."
        )
        .navigationTitle("Trip")
    }
}
