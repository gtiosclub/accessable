import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision

// Object detection with D-FINE-nano through Vision (1.1 / task T31 — replacing YOLO11, which
// is AGPL-3.0, with a permissively licensed model while keeping ObjectDetector's interface).
//
// D-FINE (Peterande/D-FINE, Apache-2.0: https://github.com/Peterande/D-FINE/blob/master/LICENSE)
// is a DETR-style detector: it always predicts a fixed set of 300 candidate boxes and is
// trained so they don't duplicate the same object the way a YOLO-style grid detector's raw
// output does, so — unlike ObjectDetector's model — it has no non-max-suppression stage
// baked in. That means Vision can't turn its output into `VNRecognizedObjectObservation`s
// automatically; this type reads the model's two raw outputs itself. `nonMaxSuppressed`
// below is a cheap safety net reusing `CGRect.intersectionOverUnion`, kept because testing
// so far (manual + `DFineObjectDetectorTests`) hasn't produced a single duplicate box.
//
// Bundled model: `dfine_n_coco.mlpackage`, the nano checkpoint converted to Core ML by
// john-rocky/peaceofcake (https://github.com/john-rocky/peaceofcake, MIT tool, Apache-2.0
// weights carried over from the original project — the license that matters is the
// weights', not the converter's). COCO 80 classes, same vocabulary `hazardLabels` already
// uses, so no change needed there.
//
// Evaluated against the bundled yolo11n model headlessly (coremltools, three real COCO
// images, not just this project's one text-reading test photo) before replacing it: D-FINE
// matched or beat yolo11n on every detection in that comparison (e.g. couch 0.85 vs 0.33,
// both cats at >0.9 vs 0.86/0.79) at roughly 2x the inference time (~8ms vs ~3-4ms on the
// same Mac) and 13MB vs 5.2MB on disk — well inside this pipeline's latency budget (T20
// targets p95 < 100ms) for a real accuracy gain, which is why this replaced yolo11n rather
// than just sitting beside it as an untested option.

/// Standard COCO 80-class order, matching D-FINE's `confidence` output columns (and the
/// same class vocabulary `hazardLabels`/the old YOLO11 model used).
let coco80ClassLabels: [String] = [
    "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
    "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
    "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
    "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
    "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
    "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
    "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
    "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse",
    "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator",
    "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush",
]

/// Decodes D-FINE's two raw outputs into `Detection`s. Pulled out of the class so it can be
/// unit-tested with synthetic `MLMultiArray`s, the same way `objectDetections` is tested
/// with `FakeObservation` rather than a real model.
///
/// - Parameters:
///   - confidence: `[queries, 80]` (or `[1, queries, 80]`; the leading batch dim, when
///     present, is dropped) — one sigmoid score per COCO class for each candidate box.
///   - coordinates: `[queries, 4]` (same batch handling) — normalized (0...1) centre-x,
///     centre-y, width, height, already top-left-origin upright (verified against Vision's
///     own output for the same images, not assumed).
func dfineDetections(
    confidence: MLMultiArray,
    coordinates: MLMultiArray,
    confidencePolicy: DetectionConfidencePolicy,
    ignoredLabels: Set<String> = [],
    classLabels: [String] = coco80ClassLabels
) -> [Detection] {
    guard let (queries, classes) = lastTwoDimensions(of: confidence), classes == classLabels.count,
          let (coordQueries, coordWidth) = lastTwoDimensions(of: coordinates),
          coordQueries == queries, coordWidth == 4
    else { return [] }

    let confidenceBase = confidence.shape.count - 2
    let coordinateBase = coordinates.shape.count - 2

    var detections: [Detection] = []
    detections.reserveCapacity(queries)
    for row in 0 ..< queries {
        var bestClass = 0
        var bestScore: Float = -.greatestFiniteMagnitude
        for column in 0 ..< classes {
            let score = confidence[index(confidenceBase, row, column)].floatValue
            if score > bestScore { bestScore = score; bestClass = column }
        }
        let label = classLabels[bestClass]
        guard !ignoredLabels.contains(label),
              confidencePolicy.accepts(label: label, confidence: bestScore)
        else { continue }

        let cx = CGFloat(coordinates[index(coordinateBase, row, 0)].floatValue)
        let cy = CGFloat(coordinates[index(coordinateBase, row, 1)].floatValue)
        let width = CGFloat(coordinates[index(coordinateBase, row, 2)].floatValue)
        let height = CGFloat(coordinates[index(coordinateBase, row, 3)].floatValue)
        let box = CGRect(x: cx - width / 2, y: cy - height / 2, width: width, height: height)

        detections.append(Detection(
            label: label, confidence: bestScore, boundingBox: box,
            origin: .model, isHazard: hazardLabels.contains(label)
        ))
    }
    return nonMaxSuppressed(detections.sorted { $0.confidence > $1.confidence })
}

/// One threshold for every class; see the `confidencePolicy` overload.
func dfineDetections(
    confidence: MLMultiArray,
    coordinates: MLMultiArray,
    minimumConfidence: Float,
    ignoredLabels: Set<String> = [],
    classLabels: [String] = coco80ClassLabels
) -> [Detection] {
    dfineDetections(
        confidence: confidence, coordinates: coordinates,
        confidencePolicy: DetectionConfidencePolicy(defaultThreshold: minimumConfidence),
        ignoredLabels: ignoredLabels, classLabels: classLabels
    )
}

/// The last two dimensions of a multi-array's shape, ignoring a leading batch dimension if
/// one is present. This genuinely varies by call path for this exact model, confirmed by
/// running both: `coremltools` (Python, used to evaluate this model before bundling it)
/// returns `[1, 300, 80]`; `VNCoreMLRequest` against the compiled `.mlmodelc` in the app
/// (verified by loading the real build output) returns `[300, 80]`, no batch dimension.
/// Indexing from the end rather than assuming one shape is why both work.
private func lastTwoDimensions(of array: MLMultiArray) -> (Int, Int)? {
    guard array.shape.count >= 2 else { return nil }
    return (array.shape[array.shape.count - 2].intValue, array.shape[array.shape.count - 1].intValue)
}

private func index(_ leadingZeros: Int, _ row: Int, _ column: Int) -> [NSNumber] {
    Array(repeating: NSNumber(0), count: leadingZeros) + [NSNumber(value: row), NSNumber(value: column)]
}

/// Greedy same-label suppression: drops a box that overlaps a higher-confidence box of the
/// same label by more than `iouThreshold`. `detections` must already be sorted by
/// confidence, highest first.
private func nonMaxSuppressed(_ detections: [Detection], iouThreshold: CGFloat = 0.5) -> [Detection] {
    var kept: [Detection] = []
    for detection in detections {
        let suppressed = kept.contains {
            $0.label == detection.label && $0.boundingBox.intersectionOverUnion(with: detection.boundingBox) > iouThreshold
        }
        if !suppressed { kept.append(detection) }
    }
    return kept
}

/// Runs the bundled D-FINE model on camera frames or still images. Mirrors `ObjectDetector`'s
/// shape (same lazy, locked model load) so the two are interchangeable from `ScenePerception`'s
/// point of view; see `ObjectDetecting`.
///
/// `@unchecked Sendable` because `VNCoreMLModel` is not `Sendable`. Safe for the same reason
/// as `ObjectDetector`: the model is created once under `lock` and never mutated after.
final class DFineObjectDetector: ObjectDetecting, @unchecked Sendable {
    /// Per-class thresholds (T39): 0.6, chairs at 0.55. Tuned on YOLO11n and carried over
    /// to D-FINE untuned; re-check them against this model on real data.
    let confidencePolicy: DetectionConfidencePolicy
    /// People come from T14's dedicated detector; reporting them here too would double them.
    let ignoredLabels: Set<String> = ["person"]

    private let modelURL: URL
    private let lock = NSLock()
    private var model: Result<VNCoreMLModel, any Error>?

    /// Returns nil when the compiled model is not in `bundle`.
    convenience init?(modelName: String = "dfine_n_coco", bundle: Bundle = .main, confidencePolicy: DetectionConfidencePolicy = .standard) {
        guard let url = bundle.url(forResource: modelName, withExtension: "mlmodelc") else { return nil }
        self.init(compiledModelURL: url, confidencePolicy: confidencePolicy)
    }

    /// From a compiled model (`.mlmodelc`) anywhere on disk, e.g. one compiled for the
    /// T20 test-set run, where the model isn't in a bundle.
    init(compiledModelURL: URL, confidencePolicy: DetectionConfidencePolicy = .standard) {
        modelURL = compiledModelURL
        self.confidencePolicy = confidencePolicy
    }

    func detect(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) throws -> [Detection] {
        try run(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation))
    }

    /// Detects objects in a still image, for photo testing and the T20 test set.
    func detect(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> [Detection] {
        try run(VNImageRequestHandler(cgImage: cgImage, orientation: orientation))
    }

    private func run(_ handler: VNImageRequestHandler) throws -> [Detection] {
        let request = VNCoreMLRequest(model: try loadedModel())
        // Same as ObjectDetector: fill rather than crop, and verified (not assumed) against
        // the model's own training preprocessing by comparing boxes to Vision's for the same
        // images before this model was bundled.
        request.imageCropAndScaleOption = .scaleFill
        try handler.perform([request])

        guard let results = request.results as? [VNCoreMLFeatureValueObservation] else { return [] }
        var confidence: MLMultiArray?
        var coordinates: MLMultiArray?
        for result in results {
            switch result.featureName {
            case "confidence": confidence = result.featureValue.multiArrayValue
            case "coordinates": coordinates = result.featureValue.multiArrayValue
            default: break
            }
        }
        guard let confidence, let coordinates else { return [] }
        return dfineDetections(confidence: confidence, coordinates: coordinates, confidencePolicy: confidencePolicy, ignoredLabels: ignoredLabels)
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
