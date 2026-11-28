import CoreML
import CoreVideo
import Foundation
import ImageIO
import Synchronization
import Vision
import os

/// Segments the ground (`SurfaceMap`) beside the perception pipeline. Owner: Computer Vision (1.1).
///
/// Runs a semantic-segmentation model on its own queue at most once per `interval`, like
/// `TextReader` does OCR, so it never delays an obstacle warning. Each frame picks up the
/// latest map.
///
/// The first bundled model in `preferredModels` is used. Apple's Core ML DETR (COCO-panoptic)
/// comes first: on 300 COCO street scenes it told sidewalk from road best of everything tried
/// (sidewalk IoU 42%, road 55%, vs 30% / 53% for SegFormer-B1 on ADE20K and under 20% / 38%
/// for SegFormer on Cityscapes, which only knows a dashcam's view;
/// `Scripts/models/benchmark_segmentation.py`). SegFormer-ADE is the fallback: better indoors
/// (floor, ceiling, stairs) and half the time, 7–26 MB instead of 86. None is in git:
/// `sh Scripts/download-models.sh` fetches them. Without any, `init` returns nil and the
/// pipeline runs as before.
///
/// The model loads on the first segmentation, on `queue`, not at app launch.
///
/// `@unchecked Sendable` because `VNCoreMLModel` is not `Sendable`. It is safe because the
/// model is only created and used on `queue`, one segmentation at a time; the rest of the
/// state is behind a `Mutex`.
final class SurfaceReader: @unchecked Sendable {
    /// Bundled model names without extension, best first.
    static let preferredModels = ["DETRResnet50SemanticSegmentationF16", "segformer_b1_ade", "segformer_b0_ade"]

    private let modelURL: URL
    /// The model and its class labels by output index; loaded on `queue` when first needed.
    private var loaded: (model: VNCoreMLModel, labels: [SurfaceKind])?
    private var loadFailed = false
    private let interval: TimeInterval
    /// Cells per side of the stored map; the models' 128–448 cells a side is more than needed.
    private let side = 56
    /// A map older than this is stale, so the ground ahead is treated as unknown.
    private let freshness: TimeInterval = 1.5
    private let queue: DispatchQueue
    /// Copies are scaled to this many pixels a side, the largest bundled model input (DETR
    /// takes 448, SegFormer 512). `.scaleFill` stretches to the model's square input anyway.
    private static let inputSide = 512
    private let copier = PixelBufferCopier(size: (SurfaceReader.inputSide, SurfaceReader.inputSide))
    private let log = Logger(subsystem: "AccessAble", category: "SurfaceReader")

    private struct State {
        var isReading = false
        var lastReadStart = -TimeInterval.infinity
        var map: SurfaceMap?
        var mapTime = -TimeInterval.infinity
        var generation = 0
    }

    private let state = Mutex(State())

    convenience init?(interval: TimeInterval = 0.4, bundle: Bundle = .main) {
        guard let url = Self.preferredModels.lazy.compactMap({ bundle.url(forResource: $0, withExtension: "mlmodelc") }).first
        else { return nil }
        self.init(compiledModelURL: url, interval: interval)
    }

    /// From a compiled model anywhere on disk (tests). `queue` runs the segmentations; tests
    /// pass one they can suspend.
    init(
        compiledModelURL: URL,
        interval: TimeInterval = 0.4,
        queue: DispatchQueue = DispatchQueue(label: "AccessAble.SurfaceReader", qos: .utility)
    ) {
        modelURL = compiledModelURL
        self.interval = interval
        self.queue = queue
    }

    /// Loads the model the first time; on `queue` only.
    private func loadedModel() -> (model: VNCoreMLModel, labels: [SurfaceKind])? {
        if let loaded { return loaded }
        guard !loadFailed else { return nil }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let mlModel = try MLModel(contentsOf: modelURL, configuration: configuration)
            let labels = Self.classNames(of: mlModel).map(SurfaceKind.init(label:))
            guard !labels.isEmpty else { throw CocoaError(.coderValueNotFound) }
            loaded = (try VNCoreMLModel(for: mlModel), labels)
        } catch {
            loadFailed = true
            log.error("surface model failed to load: \(error.localizedDescription, privacy: .public)")
        }
        return loaded
    }

    /// Starts a segmentation of `image` if the previous one has finished and `interval` has
    /// passed since it started.
    func readIfDue(_ image: CVPixelBuffer, orientation: CGImagePropertyOrientation, at time: TimeInterval) {
        let isDue = state.withLock { state in
            guard !state.isReading, time - state.lastReadStart >= interval else { return false }
            state.isReading = true
            state.lastReadStart = time
            return true
        }
        guard isDue else { return }

        let copy: CVPixelBuffer
        do { copy = try copier.copy(image) } catch {
            state.withLock { $0.isReading = false }
            log.error("segmentation skipped: could not copy camera buffer: \(String(describing: error), privacy: .public)")
            return
        }
        let request = SegmentRequest(image: copy, orientation: orientation, time: time)
        queue.async { [self] in
            let kinds = segment(request)
            state.withLock { state in
                state.isReading = false
                guard let kinds else { return }
                state.generation += 1
                state.map = SurfaceMap(width: side, height: side, kinds: kinds, generation: state.generation)
                state.mapTime = request.time
            }
        }
    }

    /// The latest map, if recent enough to describe what is in front of the camera now.
    func current(at time: TimeInterval) -> SurfaceMap? {
        state.withLock { time - $0.mapTime <= freshness ? $0.map : nil }
    }

    private func segment(_ request: SegmentRequest) -> [SurfaceKind]? {
        guard let (model, labels) = loadedModel() else { return nil }
        let vision = VNCoreMLRequest(model: model)
        // Stretch rather than crop, so the whole upright image maps straight onto the grid.
        vision.imageCropAndScaleOption = .scaleFill
        do {
            try VNImageRequestHandler(cvPixelBuffer: request.image, orientation: request.orientation).perform([vision])
        } catch {
            log.error("segmentation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let output = (vision.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue,
              output.shape.count == 2
        else { return nil }
        let rows = output.shape[0].intValue, columns = output.shape[1].intValue
        let rowStride = output.strides[0].intValue, columnStride = output.strides[1].intValue
        let pointer = output.dataPointer.assumingMemoryBound(to: Int32.self)
        var kinds: [SurfaceKind] = []
        kinds.reserveCapacity(side * side)
        for row in 0 ..< side {
            let sourceRow = min(rows - 1, (row * rows + rows / 2) / side)
            for column in 0 ..< side {
                let sourceColumn = min(columns - 1, (column * columns + columns / 2) / side)
                let index = Int(pointer[sourceRow * rowStride + sourceColumn * columnStride])
                kinds.append(labels.indices.contains(index) ? labels[index] : .other)
            }
        }
        return kinds
    }

    /// The class names: `classes` in the metadata of a model we exported, or the ones Apple
    /// ships in its model's preview metadata.
    static func classNames(of model: MLModel) -> [String] {
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        if let listed = metadata?["classes"], !listed.isEmpty {
            return listed.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }
        guard let json = metadata?["com.apple.coreml.model.preview.params"]?.data(using: .utf8),
              let params = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let labels = params["labels"] as? [String]
        else { return [] }
        return labels
    }
}

/// Carries a scaled copy of the image to the segmentation queue. `@unchecked Sendable` for
/// the same reason as `TextReader`'s request: the buffer is our copy, only read, on the
/// segmentation queue.
private struct SegmentRequest: @unchecked Sendable {
    let image: CVPixelBuffer
    let orientation: CGImagePropertyOrientation
    let time: TimeInterval
}
