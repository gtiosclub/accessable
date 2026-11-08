import MapKit
import SwiftUI

/// Owner: Maps (2.x). Home screen: camera (or map) behind Settings, Info, and Search Destination.
struct LandingView: View {
    @Environment(AppRouter.self) private var router
    @State private var showsMap = false
    @State private var showsCommands = false

    var body: some View {
        ZStack {
            if showsMap {
                CampusMap()
            } else {
                CameraBackdrop()
            }

            VStack(spacing: 12) {
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
                Spacer()
                if showsMap {
                    Text("Two fingers swipe right for camera view.")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.7), in: Capsule())
                        .accessibilityHidden(true)
                }
                Button("Search Destination") { router.push(.search) }
                    .buttonStyle(.pill(.primary))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .gesture(TwoFingerSwipe { showsMap.toggle() })
        .accessibilityAction(named: showsMap ? "Show camera view" : "Show map view") { showsMap.toggle() }
        .animation(.easeInOut(duration: 0.25), value: showsMap)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showsCommands) {
            VoiceCommandsSheet()
        }
    }
}

/// Satellite map of campus with the sample places marked.
struct CampusMap: View {
    var routeLine: [CLLocationCoordinate2D]?

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: SampleContent.campusLatitude, longitude: SampleContent.campusLongitude),
            latitudinalMeters: 1200,
            longitudinalMeters: 1200
        ))) {
            ForEach(SampleContent.places) { place in
                Marker(place.name, coordinate: place.coordinate)
            }
            if let routeLine, let current = routeLine.first {
                MapPolyline(coordinates: routeLine)
                    .stroke(.white, lineWidth: 6)
                Annotation("You", coordinate: current) {
                    Image(systemName: "location.north.fill")
                        .font(.title)
                        .foregroundStyle(Color(red: 0.2, green: 0.2, blue: 0.75))
                        .padding(18)
                        .background(.white.opacity(0.7), in: Circle())
                }
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
