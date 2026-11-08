import SwiftUI

/// Every feature screen from before the redesign, grouped by subteam, so the working
/// computer vision, maps, haptics, and command features stay easy to test.
/// Opened from the hammer button on the landing page and from Settings.
struct DeveloperToolsView: View {
    @Environment(AppViewModel.self) private var app

    var body: some View {
        List {
            Section {
                link("Original home screen", systemImage: "house",
                     hint: "Describe my surroundings and the latest announcement") {
                    HomeView(services: app.services)
                }
            } footer: {
                Text("The main screen from before the redesign.")
            }

            Section("Computer Vision") {
                // One camera screen; Walk, Find, Read and Describe are switched at its top.
                link("Camera guidance", systemImage: "camera.viewfinder",
                     hint: "Announces obstacles as you walk. Also finds places, reads signs and describes what is around you.") {
                    LiveSceneView(services: app.services, mode: .walk)
                }
                link("Read signs & text", systemImage: "text.viewfinder",
                     hint: "Reads signs and text the camera sees, with where they are") {
                    LiveSceneView(services: app.services, mode: .read)
                }
                link("Photo detection", systemImage: "photo",
                     hint: "Runs object detection on a photo") {
                    PhotoDetectionView()
                }
            }

            Section("Maps") {
                link("Trip", systemImage: "figure.walk",
                     hint: "Search a destination and walk a real route") {
                    TripView(services: app.services)
                }
                #if DEBUG
                link("Location readings", systemImage: "location",
                     hint: "Shows the location permission and the latest GPS readings") {
                    LocationDebugView(services: app.services)
                }
                #endif
            }

            Section("Haptics") {
                link("Haptic patterns", systemImage: "iphone.radiowaves.left.and.right",
                     hint: "Plays each haptic pattern") {
                    HapticsPracticeView(services: app.services)
                }
            }

            Section("Interaction") {
                link("Commands", systemImage: "text.bubble",
                     hint: "Type a command or ask a question") {
                    CommandView(services: app.services)
                }
            }
        }
        .navigationTitle("Developer Tools")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func link<Destination: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        hint: LocalizedStringKey,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            Label(title, systemImage: systemImage)
                .frame(minHeight: AccessibilityMetrics.minimumTapTarget)
        }
        .accessibilityHint(hint)
    }
}

#Preview {
    let app = AppViewModel.preview
    NavigationStack {
        DeveloperToolsView()
    }
    .environment(app)
    .preferredColorScheme(.dark)
}
