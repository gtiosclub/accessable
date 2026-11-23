import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision

// Object detection with a DETR-style model through Vision (1.1 / tasks T13, T31).
//
// DETR-style detectors (RF-DETR, D-FINE) predict a fixed set of candidate boxes and are
// trained not to duplicate one object, so they ship without a non-max-suppression stage and
// Vision can't turn their output into `VNRecognizedObjectObservation`s. This type reads the
// two raw outputs itself. Every bundled model has the same contract:
//
// - input `image` (Vision scales the frame to the model's square input, `.scaleFill`);
// - `confidence`: `[queries, classes]` per-class scores, already through a sigmoid;
// - `coordinates`: `[queries, 4]` normalised centre-x, centre-y, width, height, top-left origin.
//
// The class list comes from the model's own metadata (`classes`, comma-separated), so a model
// fine-tuned on our outdoor classes drops in without code changes; models without it (the
// D-FINE package) are COCO-80.
//
// Bundled models, best first (`DETRObjectDetector.bundled()` picks the first present):
//
// | Package            | What                                     | Threshold |
// |--------------------|------------------------------------------|-----------|
// | `rfdetr_s_outdoor` | RF-DETR Small fine-tuned on street scenes | 0.45      |
// | `rfdetr_s_coco`    | RF-DETR Small, COCO weights, 512 px      | 0.45      |
// | `dfine_n_coco`     | D-FINE nano, COCO weights, 640 px        | 0.6       |
//
// On 300 COCO street images (`Scripts/models/benchmark_detectors.py`, decoded exactly as
// below) RF-DETR Small at 0.45 found 60% of the people, vehicles and street furniture the app
// warns about at 85% precision; D-FINE nano at 0.6 found 48% at 84%. AP 47.4 vs 38.8. It costs
// about twice the time per frame (33 vs 18 ms on an M4 Mac). The RF-DETR packages are built
// by `Scripts/models/export_rfdetr_coreml.py` and are not in git; without them the app runs
// D-FINE as before.

/// Standard COCO 80-class order: the columns of a COCO model's `confidence` output.
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

/// Decodes a DETR-style model's two raw outputs into `Detection`s. Pulled out of the class so
/// it can be unit-tested with synthetic `MLMultiArray`s.
///
/// - Parameters:
///   - confidence: `[queries, classes]` (or `[1, queries, classes]`; a leading batch dim is
///     ignored) sigmoid scores, one column per entry of `classLabels`.
///   - coordinates: `[queries, 4]` (same batch handling): normalised centre-x, centre-y,
///     width, height, top-left origin, upright.
func detrDetections(
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
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull, box.width > 0, box.height > 0 else { continue }

        detections.append(Detection(
            label: label, confidence: bestScore, boundingBox: box,
            origin: .model, isHazard: hazardLabels.contains(label)
        ))
    }
    return nonMaxSuppressed(detections.sorted { $0.confidence > $1.confidence })
}

/// One threshold for every class; see the `confidencePolicy` overload.
func detrDetections(
    confidence: MLMultiArray,
    coordinates: MLMultiArray,
    minimumConfidence: Float,
    ignoredLabels: Set<String> = [],
    classLabels: [String] = coco80ClassLabels
) -> [Detection] {
    detrDetections(
        confidence: confidence, coordinates: coordinates,
        confidencePolicy: DetectionConfidencePolicy(defaultThreshold: minimumConfidence),
        ignoredLabels: ignoredLabels, classLabels: classLabels
    )
}

/// The last two dimensions of a multi-array's shape, ignoring a leading batch dimension if
/// one is present. `coremltools` returns `[1, 300, 80]` for D-FINE, `VNCoreMLRequest` against
/// the compiled model returns `[300, 80]`; indexing from the end handles both.
private func lastTwoDimensions(of array: MLMultiArray) -> (Int, Int)? {
    guard array.shape.count >= 2 else { return nil }
    return (array.shape[array.shape.count - 2].intValue, array.shape[array.shape.count - 1].intValue)
}

private func index(_ leadingZeros: Int, _ row: Int, _ column: Int) -> [NSNumber] {
    Array(repeating: NSNumber(0), count: leadingZeros) + [NSNumber(value: row), NSNumber(value: column)]
}

/// Greedy same-label suppression: drops a box that overlaps a higher-confidence box of the
/// same label by more than `iouThreshold`. `detections` must already be sorted by
/// confidence, highest first. A safety net: DETR models rarely emit duplicates.
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

/// The class list stored in a model's metadata by `export_rfdetr_coreml.py`, or nil.
func detectorClassLabels(in description: MLModelDescription) -> [String]? {
    let metadata = description.metadata[.creatorDefinedKey] as? [String: String]
    guard let listed = metadata?["classes"], !listed.isEmpty else { return nil }
    return listed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
}

/// Runs a bundled DETR-style model on camera frames or still images.
///
/// `@unchecked Sendable` because `VNCoreMLModel` is not `Sendable`. Safe because the model is
/// created once under `lock` and never mutated after; Vision lets one model serve concurrent
/// requests.
final class DETRObjectDetector: ObjectDetecting, @unchecked Sendable {
    /// A bundled model and the thresholds tuned for it.
    struct BundledModel: Sendable {
        let name: String
        let confidencePolicy: DetectionConfidencePolicy
    }

    /// Best first. RF-DETR's scores run lower than D-FINE's for the same precision, so it
    /// gets its own thresholds (see the table at the top of this file).
    static let preferredModels: [BundledModel] = [
        BundledModel(name: "rfdetr_s_outdoor", confidencePolicy: .rfdetr),
        BundledModel(name: "rfdetr_s_coco", confidencePolicy: .rfdetr),
        BundledModel(name: "dfine_n_coco", confidencePolicy: .standard),
    ]

    /// The best model in `bundle`, or nil when none is there.
    static func bundled(in bundle: Bundle = .main) -> DETRObjectDetector? {
        for candidate in preferredModels {
            if let detector = DETRObjectDetector(modelName: candidate.name, bundle: bundle, confidencePolicy: candidate.confidencePolicy) {
                return detector
            }
        }
        return nil
    }

    let confidencePolicy: DetectionConfidencePolicy
    /// People come from T14's dedicated detector; reporting them here too would double them.
    let ignoredLabels: Set<String> = ["person"]
    /// The package's name without extension, for the developer readout.
    let modelName: String

    private let modelURL: URL
    private let lock = NSLock()
    private var model: Result<(model: VNCoreMLModel, labels: [String]), any Error>?

    /// Returns nil when the compiled model is not in `bundle`.
    convenience init?(modelName: String, bundle: Bundle = .main, confidencePolicy: DetectionConfidencePolicy) {
        guard let url = bundle.url(forResource: modelName, withExtension: "mlmodelc") else { return nil }
        self.init(compiledModelURL: url, confidencePolicy: confidencePolicy)
    }

    /// From a compiled model (`.mlmodelc`) anywhere on disk, e.g. one compiled for the
    /// T20 test-set run, where the model isn't in a bundle.
    init(compiledModelURL: URL, confidencePolicy: DetectionConfidencePolicy = .standard) {
        modelURL = compiledModelURL
        modelName = compiledModelURL.deletingPathExtension().lastPathComponent
        self.confidencePolicy = confidencePolicy
    }

    /// The model's class names, loading it if needed.
    func classLabels() throws -> [String] { try loadedModel().labels }

    func detect(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) throws -> [Detection] {
        try run(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation))
    }

    /// Detects objects in a still image, for photo testing and the T20 test set.
    func detect(cgImage: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> [Detection] {
        try run(VNImageRequestHandler(cgImage: cgImage, orientation: orientation))
    }

    private func run(_ handler: VNImageRequestHandler) throws -> [Detection] {
        let loaded = try loadedModel()
        let request = VNCoreMLRequest(model: loaded.model)
        // Fill rather than crop: what both models were exported for, and objects at the
        // frame's edges are still seen.
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
        return detrDetections(
            confidence: confidence, coordinates: coordinates, confidencePolicy: confidencePolicy,
            ignoredLabels: ignoredLabels, classLabels: loaded.labels
        )
    }

    private func loadedModel() throws -> (model: VNCoreMLModel, labels: [String]) {
        try lock.withLock {
            if model == nil {
                model = Result {
                    let mlModel = try MLModel(contentsOf: modelURL)
                    let labels = detectorClassLabels(in: mlModel.modelDescription) ?? coco80ClassLabels
                    return (try VNCoreMLModel(for: mlModel), labels)
                }
            }
            return try model!.get()
        }
    }
}
