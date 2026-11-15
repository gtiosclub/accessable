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

/// Satellite map of campus with the sample places marked, the route when there is one, and
/// the user where they really are. It follows the user until they pan the map themselves.
struct CampusMap: View {
    var routeLine: [CLLocationCoordinate2D]?

    /// Shown until a location arrives, and in previews.
    private static let campus = MapCameraPosition.region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: SampleContent.campusLatitude, longitude: SampleContent.campusLongitude),
        latitudinalMeters: 1200,
        longitudinalMeters: 1200
    ))

    @State private var position = MapCameraPosition.userLocation(fallback: campus)

    var body: some View {
        Map(position: $position) {
            ForEach(SampleContent.places) { place in
                Marker(place.name, coordinate: place.coordinate)
            }
            if let routeLine {
                MapPolyline(coordinates: routeLine)
                    .stroke(.white, lineWidth: 6)
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
    }
}

#Preview {
    NavigationStack {
        LandingView()
    }
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
