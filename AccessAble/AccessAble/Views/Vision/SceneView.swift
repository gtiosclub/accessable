import SwiftUI

/// Owner: Computer Vision (1.x). Placeholder UI — replace the list with the camera preview/overlay.
struct SceneView: View {
    @State private var viewModel: SceneViewModel

    init(services: AppServices) {
        _viewModel = State(initialValue: SceneViewModel(services: services))
    }

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red)
            }

            Section("Detected") {
                ForEach(viewModel.observation.prioritizedDetections) { detection in
                    Text(SpokenPhrasing.describe(detection))
                }
            }

            Section {
                Button("Describe my surroundings") {
                    Task { await viewModel.describe() }
                }
                .accessibilityHint("Speaks a summary of what the camera sees")
                if let description = viewModel.description {
                    Text(description)
                }
            }
        }
        .navigationTitle("Camera guidance")
        .task { await viewModel.start() }
        .onDisappear { Task { await viewModel.stop() } }
    }
}

#Preview {
    NavigationStack {
        SceneView(services: .preview)
    }
}
