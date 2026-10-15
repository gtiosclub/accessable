import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision

// Object detection with a Core ML model through Vision (1.1 / task T13).
//
// The bundled model is YOLO11n (COCO classes), exported with non-maximum suppression
// built in by Scripts/export_yolo.py, so Vision returns labelled boxes directly. Any
// detector exported the same way can replace it by changing `modelName` and, if its
// vocabulary differs, `hazardLabels`.
//
// Licensing: Ultralytics YOLO11 is AGPL-3.0. That is fine for the club build, but it must
// be resolved (commercial licence or a permissively licensed model) before any App Store
// or other public distribution.

/// Anything shaped like a Vision object-recognition result, so the conversion below can
/// be tested without running a model.
protocol RecognizedObjectObservation {
    /// Normalized 0...1 with the origin at bottom-left, Vision's convention.
    var boundingBox: CGRect { get }
    var confidence: Float { get }
    var topLabel: String? { get }
}

extension VNRecognizedObjectObservation: RecognizedObjectObservation {
    var topLabel: String? { labels.first?.identifier }
}

/// COCO classes a walker can collide with or trip over. People are left out: they are
/// detected by T14 and, because they move, handled by tracking rather than as fixed hazards.
let hazardLabels: Set<String> = [
    "bench", "bicycle", "car", "chair", "couch", "dining table", "fire hydrant",
    "motorcycle", "parking meter", "potted plant", "suitcase", "truck",
]

/// Converts recognition results into `Detection`s, dropping anything below
/// `minimumConfidence`, unlabelled, or in `ignoredLabels`. Highest confidence first.
func objectDetections(
    from observations: [any RecognizedObjectObservation],
    minimumConfidence: Float,
    ignoredLabels: Set<String> = []
) -> [Detection] {
    observations
        .filter { $0.confidence >= minimumConfidence }
        .compactMap { observation in
            guard let label = observation.topLabel?.lowercased(), !label.isEmpty,
                  !ignoredLabels.contains(label)
            else { return nil }
            return Detection(
                label: label,
                confidence: observation.confidence,
                boundingBox: normalizedUprightRect(fromVisionBox: observation.boundingBox),
                origin: .model,
                isHazard: hazardLabels.contains(label)
            )
        }
        .sorted { $0.confidence > $1.confidence }
}

/// Runs the bundled object-detection model on camera frames or still images.
///
/// The model is loaded on first use rather than at app launch, on whichever queue first
/// asks for it — normally the analysis queue.
///
/// `@unchecked Sendable` because `VNCoreMLModel` is not `Sendable`. It is safe because the
/// model is created once under `lock` and never mutated afterwards; Vision allows one model
/// to serve concurrent requests.
final class ObjectDetector: @unchecked Sendable {
    /// Detections below this are discarded. At 0.4 the model reported a spoon on an
    /// abstract wallpaper at 0.51, so anything lower is too noisy to speak aloud.
    let minimumConfidence: Float
    /// People come from T14's dedicated detector; reporting them here too would double them.
    let ignoredLabels: Set<String> = ["person"]

    private let modelURL: URL
    private let lock = NSLock()
    private var model: Result<VNCoreMLModel, any Error>?

    /// Returns nil when the compiled model is not in `bundle`.
    init?(modelName: String = "yolo11n", bundle: Bundle = .main, minimumConfidence: Float = 0.5) {
        guard let url = bundle.url(forResource: modelName, withExtension: "mlmodelc") else { return nil }
        modelURL = url
        self.minimumConfidence = minimumConfidence
    }

    /// Detects objects in a frame. `orientation` describes how `pixelBuffer` is rotated
    /// relative to upright; Vision applies it, so the boxes come back upright.
    func detect(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) throws -> [Detection] {
        try run(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation))
    }

    /// Detects objects in a still image, for photo testing and the T20 test set.
    func detect(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> [Detection] {
        try run(VNImageRequestHandler(cgImage: cgImage, orientation: orientation))
    }

    private func run(_ handler: VNImageRequestHandler) throws -> [Detection] {
        let request = VNCoreMLRequest(model: try loadedModel())
        // Fill rather than crop, so objects at the frame edges are still seen.
        request.imageCropAndScaleOption = .scaleFill
        try handler.perform([request])

        return objectDetections(
            from: request.results as? [VNRecognizedObjectObservation] ?? [],
            minimumConfidence: minimumConfidence,
            ignoredLabels: ignoredLabels
        )
    }

    private func loadedModel() throws -> VNCoreMLModel {
        try lock.withLock {
            if model == nil {
                model = Result { try VNCoreMLModel(for: MLModel(contentsOf: modelURL)) }
            }
            return try model!.get()
        }
    }
}
