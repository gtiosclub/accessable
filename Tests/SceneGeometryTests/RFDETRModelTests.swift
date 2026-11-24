import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Testing
@testable import SceneGeometry

// The RF-DETR package end to end, through Vision, the way the app runs it. The package is
// built locally (`Scripts/models/export_rfdetr_coreml.py`) and isn't in git, so these skip
// when it is absent.

private let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let rfdetrPackage = repoRoot.appending(path: "AccessAble/AccessAble/Resources/rfdetr_s_coco.mlpackage")
private let hasRFDETR = FileManager.default.fileExists(atPath: rfdetrPackage.path)

private let compiledRFDETR = Task { try await MLModel.compileModel(at: rfdetrPackage) }

private func streetImage() throws -> CGImage {
    let url = try #require(Bundle.module.url(forResource: "street", withExtension: "jpg"))
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

@Suite("T31 — RF-DETR through Vision", .enabled(if: hasRFDETR, "rfdetr_s_coco.mlpackage not built"))
struct RFDETRModelTests {
    @Test("the class list comes from the model's metadata")
    func readsClassesFromMetadata() async throws {
        let detector = DETRObjectDetector(compiledModelURL: try await compiledRFDETR.value, confidencePolicy: .rfdetr)
        #expect(try detector.classLabels() == coco80ClassLabels)
    }

    @Test("finds the stop sign and the parked cars in a dusk street scene")
    func detectsStreetObjects() async throws {
        let detector = DETRObjectDetector(compiledModelURL: try await compiledRFDETR.value, confidencePolicy: .rfdetr)
        let detections = try detector.detect(cgImage: try streetImage())

        let stop = try #require(detections.first { $0.label == "stop sign" })
        // The sign sits left of centre, in the upper half (upright, top-left origin).
        #expect(stop.boundingBox.midX > 0.2 && stop.boundingBox.midX < 0.45)
        #expect(stop.boundingBox.midY > 0.2 && stop.boundingBox.midY < 0.55)
        #expect(stop.confidence > 0.7)
        #expect(detections.contains { $0.label == "car" })
        // People are left to the dedicated person detector (T14).
        #expect(!detections.contains { $0.label == "person" })
    }

    @Test("prefers RF-DETR over D-FINE when both are bundled")
    func prefersRFDETR() {
        #expect(DETRObjectDetector.preferredModels.map(\.name).firstIndex(of: "rfdetr_s_coco")!
            < DETRObjectDetector.preferredModels.map(\.name).firstIndex(of: "dfine_n_coco")!)
    }
}

// The fine-tuned outdoor model (`Scripts/training/train.py`), when built. Same checks, plus its
// class list must be the app's outdoor taxonomy in model order.
private let outdoorPackage = repoRoot.appending(path: "AccessAble/AccessAble/Resources/rfdetr_s_outdoor.mlpackage")
private let hasOutdoor = FileManager.default.fileExists(atPath: outdoorPackage.path)
private let compiledOutdoor = Task { try await MLModel.compileModel(at: outdoorPackage) }

@Suite("T31 — outdoor RF-DETR through Vision", .enabled(if: hasOutdoor, "rfdetr_s_outdoor.mlpackage not built"))
struct OutdoorRFDETRModelTests {
    @Test("its classes are OutdoorClasses.all, in order")
    func classesMatchTaxonomy() async throws {
        let detector = DETRObjectDetector(compiledModelURL: try await compiledOutdoor.value, confidencePolicy: .rfdetr)
        #expect(try detector.classLabels() == OutdoorClasses.all)
    }

    @Test("still finds the stop sign and the parked cars")
    func detectsStreetObjects() async throws {
        let detector = DETRObjectDetector(compiledModelURL: try await compiledOutdoor.value, confidencePolicy: .rfdetr)
        let detections = try detector.detect(cgImage: try streetImage())
        let stop = try #require(detections.first { $0.label == "stop sign" })
        #expect(stop.boundingBox.midX > 0.2 && stop.boundingBox.midX < 0.45)
        #expect(stop.confidence > 0.6)
        #expect(detections.contains { $0.label == "car" })
    }

    @Test("is preferred over the COCO model")
    func preferredOverCOCO() {
        let names = DETRObjectDetector.preferredModels.map(\.name)
        #expect(names.firstIndex(of: "rfdetr_s_outdoor")! < names.firstIndex(of: "rfdetr_s_coco")!)
    }
}
