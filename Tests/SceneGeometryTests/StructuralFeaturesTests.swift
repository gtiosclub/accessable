import CoreGraphics
import Testing
import simd
@testable import SceneGeometry

@Suite("T36 — doors and windows from the mesh")
struct StructuralFeaturesTests {
    /// `count` triangle centres spread over a 0.9 x 2 m door-sized patch around `center`.
    private func patch(_ label: String, at center: SIMD3<Float>, count: Int = 40) -> [MeshFaceSample] {
        (0..<count).map { i in
            let x = Float(i % 5) / 4 * 0.9 - 0.45
            let y = Float(i / 5) / 7 * 2 - 1
            return MeshFaceSample(label: label, position: center + SIMD3(x, y, 0))
        }
    }

    private func mesh(_ label: String, x: CGFloat = 0.45) -> Detection {
        Detection(
            label: label, confidence: 1, boundingBox: CGRect(x: x, y: 0.3, width: 0.1, height: 0.2),
            distance: 3, bearing: .ahead, origin: .mesh, isHazard: false
        )
    }

    @Test("a door's triangles become one door")
    func oneDoor() throws {
        let features = structuralFeatures(from: patch("door", at: [0, 1, -3]))
        #expect(features.count == 1)
        let door = try #require(features.first)
        #expect(door.label == "door")
        #expect(simd_distance(door.center, [0, 1, -3]) < 0.3)
    }

    @Test("keeps labels and far-apart features separate, drops small patches")
    func separate() {
        let samples = patch("door", at: [0, 1, -3]) + patch("door", at: [4, 1, -3])
            + patch("window", at: [0, 1.5, -3]) + patch("window", at: [-3, 1, 0], count: 5)
        let features = structuralFeatures(from: samples)
        #expect(features.count(where: { $0.label == "door" }) == 2)
        #expect(features.count(where: { $0.label == "window" }) == 1)
    }

    @Test("descriptions mention doors but not mesh windows")
    func description() {
        let observation = SceneObservation(detections: [mesh("door"), mesh("window")])
        #expect(SceneDescriptionBuilder().describe(observation) == "Door 3 metres ahead.")
    }
}
