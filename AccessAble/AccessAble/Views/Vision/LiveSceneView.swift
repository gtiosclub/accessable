import ARKit
import SceneKit
import SwiftUI

/// Owner: Computer Vision (1.1). The live camera screen: ARKit preview with detection
/// boxes drawn over it, and a readout of what the geometry detectors found.
///
/// Requires a real device — ARKit world tracking does not run in the Simulator — and a
/// LiDAR device for the floor, obstacle and kerb readouts.
struct LiveSceneView: View {
    @State private var viewModel: LiveSceneViewModel

    init(services: AppServices) {
        _viewModel = State(initialValue: LiveSceneViewModel(services: services))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let error = viewModel.errorMessage {
                unavailable(error)
            } else {
                preview
                readout
            }
        }
        .navigationTitle("Live detection")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.start() }
        .onDisappear { Task { await viewModel.stop() } }
    }

    private var preview: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ARCameraPreview(session: viewModel.analyzer.session)

                ForEach(viewModel.observation.detections) { detection in
                    DetectionBox(
                        detection: detection,
                        rect: aspectFillRect(
                            normalizedBox: detection.boundingBox,
                            imageAspectRatio: viewModel.imageAspectRatio,
                            viewSize: geometry.size
                        )
                    )
                }
            }
            // The boxes are a sighted-user debugging aid; VoiceOver gets the sentence in
            // the readout below instead of 20 unlabelled rectangles.
            .accessibilityHidden(true)
        }
        .ignoresSafeArea()
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(viewModel.floorDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)

            ForEach(Array(viewModel.hazards.enumerated()), id: \.offset) { _, hazard in
                Text(viewModel.hazardLine(hazard))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(hazard.type == .dropOff ? Color.red : Color.orange)
            }

            Text(viewModel.countsDescription)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(viewModel.spokenSummary)
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Camera guidance unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            // The usual cause is the Simulator, which has neither ARKit nor a camera.
            Text(message + "\n\nThe Simulator cannot run ARKit. Run on a physical iPhone, or try people detection on a photo instead.")
        } actions: {
            NavigationLink {
                PhotoDetectionView()
            } label: {
                Label("Detect people in a photo", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// One detection's rectangle plus its label.
private struct DetectionBox: View {
    let detection: Detection
    let rect: CGRect

    private var color: Color {
        switch detection.origin {
        case .model: .green
        case .geometric: .orange
        case .mesh: .blue
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .stroke(color, lineWidth: 3)
                .frame(width: rect.width, height: rect.height)

            Text(caption)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(color, in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.black)
                .offset(y: -18)
        }
        .offset(x: rect.minX, y: rect.minY)
    }

    private var caption: String {
        guard let distance = detection.distance else {
            return "\(detection.label) \(Int(detection.confidence * 100))%"
        }
        return String(format: "%@ %.1fm", detection.label, distance)
    }
}

/// Renders the analyzer's own ARKit session, so the preview and the detections come from
/// the same frames.
private struct ARCameraPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = true
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
