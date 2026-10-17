import SwiftUI

/// Owner: Computer Vision (1.x). Placeholder UI — replace the list with the camera preview/overlay.
struct SceneView: View {
    @State private var viewModel: SceneViewModel
    @State private var question = ""
    @State private var showsAskedImage = false
    @State private var destination = ""

    init(services: AppServices) {
        _viewModel = State(initialValue: SceneViewModel(services: services))
    }

    var body: some View {
        List {
            if viewModel.canNavigate {
                Section("Take me to") {
                    TextField("For example: the chair, exit, room 210", text: $destination)
                        .submitLabel(.go)
                        .onSubmit(navigate)
                        .accessibilityHint("What to find. Then turn slowly all the way around and follow the directions.")
                    if viewModel.isNavigating {
                        Button("Stop guiding", role: .destructive) { viewModel.navigate(to: "") }
                    } else {
                        Button("Go", action: navigate)
                            .disabled(destination.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let navigation = viewModel.navigation {
                        Text(navigation.description)
                    }
                }
            }

            Section("Ask AI") {
                TextField("Ask about what the camera sees", text: $question, axis: .vertical)
                    .submitLabel(.send)
                    .onSubmit(ask)
                    .accessibilityHint("For example: Where is Room 210?")
                Button("Ask", action: ask)
                    .disabled(trimmedQuestion.isEmpty || viewModel.isAsking)
                    .accessibilityHint("Answers your question from the current camera view, on this device")
                if viewModel.isAsking {
                    ProgressView("Looking…")
                }
                if let answer = viewModel.answer {
                    Text(answer)
                }
                if let error = viewModel.askError {
                    Text(error).foregroundStyle(.red)
                }
                if let image = viewModel.askedImage {
                    DisclosureGroup("Image used for the answer", isExpanded: $showsAskedImage) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("The camera image the answer was based on")
                    }
                }
            }

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
        // VoiceOver users shouldn't have to hunt for the answer after asking.
        .onChange(of: viewModel.answer) { _, answer in
            if let answer { AccessibilityNotification.Announcement(answer).post() }
        }
        .onChange(of: viewModel.askError) { _, error in
            if let error { AccessibilityNotification.Announcement(error).post() }
        }
        .navigationTitle("Camera guidance")
        .task { await viewModel.start() }
        .onDisappear { Task { await viewModel.stop() } }
    }

    private var trimmedQuestion: String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func navigate() {
        let target = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        viewModel.navigate(to: target)
    }

    private func ask() {
        let asked = trimmedQuestion
        guard !asked.isEmpty, !viewModel.isAsking else { return }
        Task { await viewModel.ask(asked) }
    }
}

#Preview {
    NavigationStack {
        SceneView(services: .preview)
    }
}
