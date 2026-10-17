import Foundation
import Observation
import UIKit

/// Owner: Computer Vision (1.1 / task T14). Runs people detection over a still image.
///
/// This is T14's own stated acceptance path — "test against saved images or videos" — and
/// the only way to see real Vision output without hardware, since the Simulator has
/// neither a camera nor ARKit.
@MainActor
@Observable
final class PhotoDetectionViewModel {
    private(set) var image: UIImage?
    private(set) var detections: [Detection] = []
    private(set) var errorMessage: String?
    private(set) var isAnalyzing = false

    @ObservationIgnored private let detector = PeopleDetector()

    /// Width / height of the image as displayed, for placing overlay boxes.
    var imageAspectRatio: CGFloat {
        guard let image, image.size.height > 0 else { return 1 }
        return image.size.width / image.size.height
    }

    var summary: String {
        if isAnalyzing { return "Analysing…" }
        guard image != nil else { return "Pick a photo to run people detection on it." }
        if detections.isEmpty { return "No people found." }
        let confidences = detections
            .map { "\(Int(($0.confidence * 100).rounded()))%" }
            .joined(separator: ", ")
        return "\(detections.count) person(s) found — confidence \(confidences)."
    }

    func analyze(imageData: Data) async {
        isAnalyzing = true
        defer { isAnalyzing = false }

        errorMessage = nil
        detections = []

        guard let uiImage = UIImage(data: imageData) else {
            errorMessage = "That file could not be read as an image."
            return
        }
        image = uiImage

        guard let cgImage = uiImage.cgImage else {
            errorMessage = "That image has no bitmap data to analyse."
            return
        }

        do {
            // SwiftUI renders a UIImage already rotated upright, so Vision has to be told
            // the same rotation or the boxes land on a differently-oriented picture.
            detections = try detector.detect(
                cgImage: cgImage,
                orientation: Self.orientation(for: uiImage.imageOrientation)
            )
        } catch {
            errorMessage = "Vision could not analyse that image: \(error.localizedDescription)"
        }
    }

    static func orientation(for orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
