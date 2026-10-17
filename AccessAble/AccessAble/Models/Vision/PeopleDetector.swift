import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

extension VNHumanObservation: HumanRectangleObservation {}

/// Detects people in a camera frame using Apple's Vision framework.
/// Owner: Computer Vision (1.1 / task T14).
///
/// A `Sendable` struct that builds its request per call, rather than an actor holding one
/// request alive. `VNImageRequestHandler` is per-image anyway, so an actor would only save
/// reallocating the request object — real but small — at the cost of an `await` on every
/// caller and a serialization point in the frame path. Worth revisiting if profiling says
/// the allocation matters.
struct PeopleDetector: Sendable {
    /// Observations below this are discarded.
    var minimumConfidence: Float = 0.5
    /// When true Vision returns torso-only boxes. Left false: a full-body box is what any
    /// later "estimate distance from box height" heuristic needs, and a torso box would
    /// quietly halve it.
    var upperBodyOnly: Bool = false

    init(minimumConfidence: Float = 0.5, upperBodyOnly: Bool = false) {
        self.minimumConfidence = minimumConfidence
        self.upperBodyOnly = upperBodyOnly
    }

    /// Runs people detection on one frame.
    ///
    /// `orientation` must describe how `pixelBuffer` is oriented relative to upright;
    /// Vision applies it, so the returned boxes are already in upright image space.
    ///
    /// Throws whatever Vision throws. A frame with nobody in it is not an error — that
    /// returns an empty array.
    func detect(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) throws -> [Detection] {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = upperBodyOnly

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        try handler.perform([request])

        return personDetections(
            from: request.results ?? [],
            minimumConfidence: minimumConfidence
        )
    }

    /// Runs people detection on a still image.
    ///
    /// The task sheet's own acceptance path ("test against saved images or videos"), and
    /// the only way to exercise this without a camera — the Simulator has neither a
    /// camera nor ARKit.
    func detect(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) throws -> [Detection] {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = upperBodyOnly

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        try handler.perform([request])

        return personDetections(
            from: request.results ?? [],
            minimumConfidence: minimumConfidence
        )
    }
}
