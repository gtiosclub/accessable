import ARKit
import SwiftUI

/// Owner: Computer Vision (1.1 / 1.3 / task T30). The end-user "Camera guidance" screen: a
/// live camera preview with detected objects, distances and visually distinct urgent
/// warnings, plus "Describe my surroundings", Ask AI and "Take me to…".
///
/// Boxes on the preview are a sighted/low-vision aid, same as the debug "Live detection"
/// screen (`LiveSceneView`) — VoiceOver users already get the spoken announcements plus the
/// "Detected" list below, so the preview itself is `accessibilityHidden`.
struct SceneView: View {
    @State private var viewModel: SceneViewModel
    @State private var question = ""
    @State private var showsAskedImage = false
    @State private var destination = ""

    init(services: AppServices) {
        _viewModel = State(initialValue: SceneViewModel(services: services))
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.errorMessage == nil, let analyzer = viewModel.analyzer {
                preview(analyzer)
                    .frame(height: 260)
                if let event = viewModel.lastAnnouncement {
                    AnnouncementBanner(event: event)
                        .padding([.horizontal, .top])
                }
            }

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
        }
        // VoiceOver users shouldn't have to hunt for the answer after asking.
        .onChange(of: viewModel.answer) { _, answer in
            if let answer { AccessibilityNotification.Announcement(answer).post() }
        }
        .onChange(of: viewModel.askError) { _, error in
            if let error { AccessibilityNotification.Announcement(error).post() }
        }
        .navigationTitle("Camera guidance")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.start() }
    }

    private func preview(_ analyzer: ARSceneAnalyzer) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ARCameraPreview(session: analyzer.sessionManager.session)
                ForEach(viewModel.observation.detections) { detection in
                    GuidanceDetectionBox(
                        detection: detection,
                        rect: aspectFillRect(
                            normalizedBox: detection.boundingBox,
                            imageAspectRatio: viewModel.imageAspectRatio,
                            viewSize: geometry.size
                        )
                    )
                }
            }
            .accessibilityHidden(true)
        }
        .clipped()
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

/// One detection's rectangle, coloured by how urgent it is — the "visually distinct urgent
/// warning" the old text-only screen couldn't show. Reads its distance bands from
/// `ObstacleAnnouncer`'s own defaults so the colours never disagree with what gets spoken.
private struct GuidanceDetectionBox: View {
    let detection: Detection
    let rect: CGRect

    private static let thresholds = ObstacleAnnouncer().thresholds.sorted(by: >)

    private var urgency: (color: Color, isUrgent: Bool) {
        guard detection.isHazard, let distance = detection.distance else { return (.blue, false) }
        if distance <= Double(Self.thresholds.last ?? 1.2) { return (.red, true) }
        if distance <= Double(Self.thresholds.first ?? 2.5) { return (.orange, false) }
        return (.blue, false)
    }

    var body: some View {
        let (color, isUrgent) = urgency
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .stroke(color, lineWidth: isUrgent ? 4 : 2)
                .frame(width: rect.width, height: rect.height)

            Text(caption)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(color, in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.white)
                .offset(y: -18)
        }
        .offset(x: rect.minX, y: rect.minY)
    }

    private var caption: String {
        guard let distance = detection.distance else { return detection.label }
        return String(format: "%@ %.1fm", detection.label, distance)
    }
}

#Preview {
    NavigationStack {
        SceneView(services: .preview)
    }
}
