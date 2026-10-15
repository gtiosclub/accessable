import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

/// Reads text such as room numbers, signs and labels with Apple's Vision framework.
/// Owner: Computer Vision (1.3 / task T17).
///
/// Uses the fast recognizer: it is accurate enough for short, high-contrast signage and
/// cheap enough to run on live frames. Boxes come back upright and top-left-origin, like
/// `Detection.boundingBox`.
struct TextDetector: Sendable {
    /// Readings below this are dropped. Fast recognition produces plenty of low-confidence
    /// fragments from textures and edges, and they should never be read aloud.
    var minimumConfidence: Float = 0.5

    init(minimumConfidence: Float = 0.5) {
        self.minimumConfidence = minimumConfidence
    }

    /// Reads text in a frame. `orientation` describes how `pixelBuffer` is rotated relative
    /// to upright.
    func detectText(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) throws -> [RecognizedText] {
        try run(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation))
    }

    /// Reads text in a still image.
    func detectText(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> [RecognizedText] {
        try run(VNImageRequestHandler(cgImage: cgImage, orientation: orientation))
    }

    private func run(_ handler: VNImageRequestHandler) throws -> [RecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        try handler.perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= minimumConfidence,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return RecognizedText(
                string: candidate.string,
                confidence: candidate.confidence,
                boundingBox: normalizedUprightRect(fromVisionBox: observation.boundingBox)
            )
        }
    }
}
