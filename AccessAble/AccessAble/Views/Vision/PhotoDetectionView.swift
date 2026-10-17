import PhotosUI
import SwiftUI

/// Owner: Computer Vision (1.1 / task T14). Runs Apple Vision people detection over a
/// photo and draws the boxes it returns.
///
/// Works in the Simulator, unlike the ARKit screen — this is how to check T14 without a
/// device.
struct PhotoDetectionView: View {
    @State private var viewModel = PhotoDetectionViewModel()
    @State private var selection: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 16) {
            imageArea

            Text(viewModel.summary)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            PhotosPicker(selection: $selection, matching: .images, photoLibrary: .shared()) {
                Label("Choose a photo", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Runs people detection on a photo from your library")
        }
        .padding()
        .navigationTitle("Photo detection")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selection) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                await viewModel.analyze(imageData: data)
            }
        }
    }

    @ViewBuilder
    private var imageArea: some View {
        if let image = viewModel.image {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)

                    ForEach(viewModel.detections) { detection in
                        let rect = aspectFitRect(
                            normalizedBox: detection.boundingBox,
                            imageAspectRatio: viewModel.imageAspectRatio,
                            viewSize: geometry.size
                        )
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.green, lineWidth: 3)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
            // The boxes duplicate what `summary` already says in words.
            .accessibilityHidden(true)
        } else {
            ContentUnavailableView(
                "No photo yet",
                systemImage: "person.crop.rectangle",
                description: Text("Pick a photo with people in it to see what Vision returns.")
            )
        }
    }
}

#Preview {
    NavigationStack {
        PhotoDetectionView()
    }
}
