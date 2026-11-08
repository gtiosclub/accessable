import CoreGraphics
import Foundation

// T20: recorded test set. Ground truth lives in TestSet/annotations.json, not in code.

enum TestScenario: String, Codable, CaseIterable, Sendable {
    case chairAhead = "chair-ahead"
    case chairOutsideCorridor = "chair-outside-corridor"
    case personApproaching = "person-approaching"
    case personCrossing = "person-crossing"
    case stairsUp = "stairs-up"
    case stairsDown = "stairs-down"
    case curbDropOff = "curb-drop-off"
    case multipleObjects = "multiple-objects"
    case roomSign = "room-sign"
    case dimLighting = "dim-lighting"
    case busyHallway = "busy-hallway"
}

/// A condition a test frame was recorded in (T40). A frame lists every one that applies.
enum EnvironmentalCondition: String, Codable, CaseIterable, Sendable {
    case indoor
    case outdoor
    case brightLighting = "bright-lighting"
    case dimLighting = "dim-lighting"
    case lowCrowd = "low-crowd"
    case busy
    case movingPeople = "moving-people"
}

struct AnnotatedObject: Codable, Equatable, Sendable {
    let label: String
    let x, y, width, height: Double

    var groundTruth: GroundTruthDetection {
        GroundTruthDetection(label: label, boundingBox: CGRect(x: x, y: y, width: width, height: height))
    }
}

struct AnnotatedFrame: Codable, Equatable, Sendable {
    let scenario: TestScenario
    let image: String // path relative to TestSet/
    let objects: [AnnotatedObject]
    let measuredDistances: [String: Float]? // label -> tape-measured meters
    /// label -> what the app said on the phone when the frame was taken. A saved image has
    /// no depth, so LiDAR distances can only be scored if they were recorded with it.
    var estimatedDistances: [String: Float]? = nil
    /// What the frame was recorded in (T40), so results can be split by it.
    var conditions: [EnvironmentalCondition]? = nil
}

struct TestSetManifest: Codable, Equatable, Sendable {
    let version: Int
    let frames: [AnnotatedFrame]

    static func load(from url: URL) throws -> TestSetManifest {
        try JSONDecoder().decode(TestSetManifest.self, from: Data(contentsOf: url))
    }

    // scenarios we still need to record
    var missingScenarios: [TestScenario] {
        let covered = Set(frames.map(\.scenario))
        return TestScenario.allCases.filter { !covered.contains($0) }
    }
}

// Runs a detector on every frame and scores it. `labels` limits scoring to the classes
// that detector handles (e.g. ["person"] for T14).
func evaluateDetector(
    on manifest: TestSetManifest,
    folder: URL,
    labels: Set<String>? = nil,
    detect: (URL) throws -> [Detection]
) rethrows -> DetectionMetrics {
    let cases = try manifest.frames.map { frame in
        let predicted = try detect(folder.appending(path: frame.image))
        let expected = frame.objects.map(\.groundTruth)
        return DetectionTestCase(
            expected: expected.filter { labels?.contains($0.label) ?? true },
            predicted: predicted.filter { labels?.contains($0.label) ?? true }
        )
    }
    return evaluateDetections(cases)
}

func distanceTestCases(
    from manifest: TestSetManifest,
    folder: URL,
    estimate: (URL) throws -> [String: Float]
) rethrows -> [DistanceTestCase] {
    var cases: [DistanceTestCase] = []

    for frame in manifest.frames {
        guard let actualDistances = frame.measuredDistances else {
            continue
        }

        let estimatedDistances = try estimate(
            folder.appending(path: frame.image)
        )

        for (label, actualMeters) in actualDistances {
            guard let estimatedMeters = estimatedDistances[label] else {
                continue
            }

            cases.append(
                DistanceTestCase(
                    estimatedMeters: estimatedMeters,
                    actualMeters: actualMeters
                )
            )
        }
    }

    return cases
}

func evaluateDistanceEstimates(
    on manifest: TestSetManifest,
    folder: URL,
    estimate: (URL) throws -> [String: Float]
) rethrows -> DistanceMetrics? {
    let cases = try distanceTestCases(
        from: manifest,
        folder: folder,
        estimate: estimate
    )

    return evaluateDistances(cases)
}

func calibrateDistanceEstimates(
    on manifest: TestSetManifest,
    folder: URL,
    estimate: (URL) throws -> [String: Float]
) rethrows -> DistanceCalibration? {
    let cases = try distanceTestCases(
        from: manifest,
        folder: folder,
        estimate: estimate
    )

    return fitDistanceCalibration(from: cases)
}
