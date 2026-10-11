import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision

// T13: YOLO object detection with Core ML.
// Model is YOLO11n (COCO classes) exported with NMS included, see Scripts/export_yolo.py.

protocol RecognizedObjectObservation {
    var boundingBox: CGRect { get }
    var confidence: Float { get }
    var topLabel: String? { get }
}

extension VNRecognizedObjectObservation: RecognizedObjectObservation {
    var topLabel: String? { labels.first?.identifier }
}

// Things you could walk into. People aren't included since they move (same as T14).
let hazardLabels: Set<String> = [
    "bench", "bicycle", "car", "chair", "couch", "dining table", "fire hydrant",
    "motorcycle", "parking meter", "potted plant", "suitcase", "truck",
]

// Converts Vision results to our Detection type. Kept separate so it can be tested
// without running the model.
func objectDetections(
    from observations: [any RecognizedObjectObservation],
    minimumConfidence: Float = 0.4
) -> [Detection] {
    observations
        .filter { $0.confidence >= minimumConfidence }
        .compactMap { observation in
            guard let label = observation.topLabel?.lowercased(), !label.isEmpty else { return nil }
            return Detection(
                label: label,
                confidence: observation.confidence,
                // Vision's origin is bottom-left, ours is top-left
                boundingBox: normalizedUprightRect(fromVisionBox: observation.boundingBox),
                origin: .model,
                isHazard: hazardLabels.contains(label)
            )
        }
        .sorted { $0.confidence > $1.confidence }
}

final class ObjectDetector: @unchecked Sendable {
    let minimumConfidence: Float
    private let model: VNCoreMLModel

    // Loading the model is slow, so make one detector and reuse it.
    init(minimumConfidence: Float = 0.4, bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "yolo11n", withExtension: "mlmodelc") else {
            throw ObjectDetectorError.modelNotFound
        }
        model = try VNCoreMLModel(for: MLModel(contentsOf: url))
        self.minimumConfidence = minimumConfidence
    }

    func detectObjects(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) async throws -> [Detection] {
        try run(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation))
    }

    // For still images (photo testing, T20 test set)
    func detectObjects(in image: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> [Detection] {
        try run(VNImageRequestHandler(cgImage: image, orientation: orientation))
    }

    private func run(_ handler: VNImageRequestHandler) throws -> [Detection] {
        let request = VNCoreMLRequest(model: model)
        // scaleFill so objects at the edges of the frame don't get cropped out
        request.imageCropAndScaleOption = .scaleFill
        try handler.perform([request])

        let results = request.results as? [VNRecognizedObjectObservation] ?? []
        return objectDetections(from: results, minimumConfidence: minimumConfidence)
    }
}

enum ObjectDetectorError: Error {
    case modelNotFound
}
