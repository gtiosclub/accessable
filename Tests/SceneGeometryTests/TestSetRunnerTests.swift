import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SceneGeometry

private func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}

private func prediction(_ label: String, _ rect: CGRect, distance: Double? = nil) -> Detection {
    Detection(label: label, confidence: 0.9, boundingBox: rect, distance: distance, origin: .model, isHazard: false)
}

private func frame(
    _ scenario: TestScenario,
    _ image: String,
    objects: [AnnotatedObject],
    measured: [String: Float]? = nil,
    estimated: [String: Float]? = nil,
    lighting: FrameConditions.Lighting? = nil
) -> AnnotatedFrame {
    AnnotatedFrame(
        scenario: scenario,
        image: image,
        objects: objects,
        measuredDistances: measured,
        estimatedDistances: estimated,
        conditions: lighting.map { FrameConditions(lighting: $0) }
    )
}

private let chair = AnnotatedObject(label: "chair", x: 0.4, y: 0.4, width: 0.2, height: 0.3)
private let person = AnnotatedObject(label: "person", x: 0.1, y: 0.2, width: 0.2, height: 0.6)

private let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let testSetFolder = repoRoot.appending(path: "TestSet")
private let repoManifest = try? TestSetManifest.load(from: testSetFolder.appending(path: "annotations.json"))

/// The bundled YOLO model, compiled once per test run (SwiftPM can't compile it as a resource).
private let compiledModel = Task {
    try await MLModel.compileModel(at: repoRoot.appending(path: "AccessAble/AccessAble/Resources/yolo11n.mlpackage"))
}

/// What the app runs on a frame: the object model (T13) and people detection (T14).
private func detectWithAppDetectors() async throws -> (URL) throws -> [Detection] {
    let objects = ObjectDetector(compiledModelURL: try await compiledModel.value)
    let people = PeopleDetector()
    // Load the model now so the first frame's time is detection, not loading.
    if let blank = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage() {
        _ = try objects.detect(cgImage: blank)
    }
    return { url in
        let (image, orientation) = try loadTestImage(at: url)
        return try objects.detect(cgImage: image, orientation: orientation)
            + people.detect(cgImage: image, orientation: orientation)
    }
}

@Suite("T20 — test set runner")
struct TestSetRunnerTests {
    @Test func splitsResultsByScenarioAndLighting() {
        let manifest = TestSetManifest(version: 1, frames: [
            frame(.chairAhead, "a.jpg", objects: [chair], lighting: .normal),
            frame(.busyHallway, "b.jpg", objects: [person], lighting: .dim),
        ])
        // finds the chair, misses the person
        let report = evaluateTestSet(manifest, folder: URL(filePath: "/tmp")) { url in
            url.lastPathComponent == "a.jpg" ? [prediction("chair", chair.groundTruth.boundingBox)] : []
        }
        #expect(report.frameCount == 2)
        #expect(report.overall.truePositives == 1 && report.overall.falseNegatives == 1)
        #expect(report.byScenario[.chairAhead]?.recall == 1)
        #expect(report.byScenario[.busyHallway]?.recall == 0)
        #expect(report.byLighting[.dim]?.recall == 0)
        #expect(report.byLighting[.bright] == nil)
        #expect(report.missingScenarios.count == TestScenario.allCases.count - 2)
        #expect(report.performance != nil)
    }

    @Test func labelsLimitWhatIsScored() {
        let manifest = TestSetManifest(version: 1, frames: [frame(.multipleObjects, "a.jpg", objects: [chair, person])])
        let report = evaluateTestSet(manifest, folder: URL(filePath: "/tmp"), labels: ["person"]) { _ in [] }
        #expect(report.overall.falseNegatives == 1)
    }

    @Test func recordedDistanceWinsOverPrediction() throws {
        let manifest = TestSetManifest(version: 1, frames: [
            frame(.chairAhead, "a.jpg", objects: [chair], measured: ["chair": 2.0], estimated: ["chair": 2.2]),
            frame(.chairAhead, "b.jpg", objects: [chair], measured: ["chair": 3.0]),
            frame(.chairAhead, "c.jpg", objects: [chair], measured: ["chair": 1.0]), // nothing to compare
        ])
        let report = evaluateTestSet(manifest, folder: URL(filePath: "/tmp")) { url in
            switch url.lastPathComponent {
            case "a.jpg": [prediction("chair", chair.groundTruth.boundingBox, distance: 9)]
            case "b.jpg": [prediction("chair", chair.groundTruth.boundingBox, distance: 2.8)]
            default: [prediction("chair", chair.groundTruth.boundingBox)]
            }
        }
        let distance = try #require(report.distance)
        #expect(distance.sampleCount == 2)
        #expect(abs(distance.maxAbsoluteError - 0.2) < 1e-5)
    }

    @Test func oldAnnotationsStillDecode() throws {
        let json = """
        {"version": 1, "frames": [{"scenario": "room-sign", "image": "frames/room-sign/0001.jpg", "objects": []}]}
        """
        let manifest = try JSONDecoder().decode(TestSetManifest.self, from: Data(json.utf8))
        #expect(manifest.frames[0].conditions == nil)
        #expect(manifest.frames[0].estimatedDistances == nil)

        let withConditions = """
        {"version": 1, "frames": [{"scenario": "dim-lighting", "image": "x.jpg", "objects": [],
          "conditions": {"lighting": "dim", "setting": "indoor"}}]}
        """
        let decoded = try JSONDecoder().decode(TestSetManifest.self, from: Data(withConditions.utf8))
        #expect(decoded.frames[0].conditions == FrameConditions(lighting: .dim, setting: .indoor))
    }

    @Test func summaryNamesWhatIsMissing() {
        let manifest = TestSetManifest(version: 1, frames: [frame(.chairAhead, "a.jpg", objects: [chair])])
        let summary = evaluateTestSet(manifest, folder: URL(filePath: "/tmp")) { _ in [] }.summary
        #expect(summary.contains("1 frames, 1 of 11 scenarios"))
        #expect(summary.contains("chair-ahead"))
        #expect(summary.contains("not recorded yet: chair-outside-corridor"))
    }

    @Test func readsExifOrientation() throws {
        let context = try #require(CGContext(
            data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let loaded = try loadTestImage(at: url)
        #expect(loaded.orientation == .right)
        #expect(throws: TestImageError.self) { try loadTestImage(at: URL(filePath: "/nonexistent.jpg")) }
    }

    /// The real detectors, end to end, on the bundled sign image: nothing in it is an
    /// object or a person, so any detection is a false positive.
    @Test func appDetectorsRunOnAStill() async throws {
        let folder = try #require(Bundle.module.url(forResource: "room210", withExtension: "jpg")).deletingLastPathComponent()
        let manifest = TestSetManifest(version: 1, frames: [frame(.roomSign, "room210.jpg", objects: [])])
        let report = try evaluateTestSet(manifest, folder: folder, detect: try await detectWithAppDetectors())
        print(report.summary)
        #expect(report.overall.falsePositives == 0)
    }

    /// The recorded set in TestSet/. Prints the report; skipped until frames are added (T40).
    @Test(.enabled(if: !(repoManifest?.frames.isEmpty ?? true)))
    func recordedTestSet() async throws {
        let manifest = try #require(repoManifest)
        for frame in manifest.frames {
            #expect(FileManager.default.fileExists(atPath: testSetFolder.appending(path: frame.image).path), "missing \(frame.image)")
        }
        let report = try evaluateTestSet(manifest, folder: testSetFolder, detect: try await detectWithAppDetectors())
        print("\n" + report.summary + "\n")
    }
}
