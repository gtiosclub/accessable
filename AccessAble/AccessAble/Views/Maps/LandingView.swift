import MapKit
import SwiftUI

/// Owner: Maps (2.x). Home screen: Settings, Dev Tools and Voice commands at the top, Search
/// Destination at the bottom, over a plain background for now (a static image is to come).
///
/// There is no camera or map here, so no camera/map switch either: the camera runs on the
/// trip screen, where the switch is, and from Dev Tools.
struct LandingView: View {
    @Environment(AppRouter.self) private var router
    @State private var showsCommands = false

    var body: some View {
        VStack(spacing: 12) {
            topBar
            Spacer()
            searchButton
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.navy.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showsCommands) {
            VoiceCommandsSheet()
        }
    }

    private var topBar: some View {
        HStack {
            CircleIconButton(systemImage: "gearshape", label: "Settings") {
                router.push(.settings)
            }
            Spacer()
            Button {
                router.push(.developerTools)
            } label: {
                Label("Dev Tools", systemImage: "hammer.fill")
            }
            .buttonStyle(.pill(.outline, size: .compact))
            .background(.black.opacity(0.6), in: Capsule())
            .accessibilityLabel("Developer tools")
            .accessibilityHint("Computer vision, maps, haptics, and command features")
            Spacer()
            CircleIconButton(systemImage: "info", label: "Voice commands") {
                showsCommands = true
            }
        }
    }

    private var searchButton: some View {
        Button("Search Destination") { router.push(.search) }
            .buttonStyle(.pill(.primary))
    }
}

/// Satellite map of campus with the real route, the destination, and the user where they
/// really are. It follows the user until they pan the map themselves. VoiceOver reads it as
/// one element with `accessibilityLabel`; the spoken directions carry the details.
struct CampusMap: View {
    var routeLine: [CLLocationCoordinate2D]?
    var destination: Destination?
    var accessibilityLabel = "Map"
    @Environment(\.colorSchemeContrast) private var contrast

    /// Shown until a location arrives, and in previews.
    private static let campus = MapCameraPosition.region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: SampleContent.campusLatitude, longitude: SampleContent.campusLongitude),
        latitudinalMeters: 1200,
        longitudinalMeters: 1200
    ))

    @State private var position = MapCameraPosition.userLocation(fallback: campus)

    var body: some View {
        Map(position: $position) {
            if let routeLine {
                // a dark casing keeps the white line visible over roofs, roads and grass alike
                MapPolyline(coordinates: routeLine)
                    .stroke(.black, style: routeStroke(width: routeWidth + 4))
                MapPolyline(coordinates: routeLine)
                    .stroke(.white, style: routeStroke(width: routeWidth))
            }
            if let destination {
                Marker(destination.name, systemImage: "flag.checkered", coordinate: destination.coordinate.clCoordinate)
            }
            // The real location, so it moves with each fix (and with a simulated GPX walk).
            UserAnnotation {
                Image(systemName: "location.north.fill")
                    .font(.title)
                    .foregroundStyle(Color(red: 0.2, green: 0.2, blue: 0.75))
                    .padding(18)
                    .background(.white.opacity(0.7), in: Circle())
            }
        }
        .mapStyle(.imagery(elevation: .flat))
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Points; thicker when Increase Contrast is on.
    private var routeWidth: CGFloat { contrast == .increased ? 10 : 7 }

    private func routeStroke(width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }
}

#Preview {
    NavigationStack {
        LandingView()
    }
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
