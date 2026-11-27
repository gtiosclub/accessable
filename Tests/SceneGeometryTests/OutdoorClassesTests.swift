import Foundation
import Testing
@testable import SceneGeometry

private let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private struct Taxonomy: Decodable {
    struct Entry: Decodable { let name: String }
    let classes: [Entry]
}

@Suite("Outdoor detector classes")
struct OutdoorClassesTests {
    @Test("the app's list matches the training taxonomy, in order")
    func matchesTaxonomy() throws {
        let data = try Data(contentsOf: repoRoot.appending(path: "Scripts/training/taxonomy.json"))
        let taxonomy = try JSONDecoder().decode(Taxonomy.self, from: data)
        #expect(taxonomy.classes.map(\.name) == OutdoorClasses.all)
    }

    @Test("street furniture is a hazard, rated high, and fuses with geometry")
    func streetFurniture() {
        for label in ["pole", "bollard", "trash can", "traffic cone", "barrier"] {
            #expect(hazardLabels.contains(label))
            #expect(fusableLabels.contains(label))
            #expect(DangerLevel(of: Detection(label: label, confidence: 1, boundingBox: .zero, origin: .model, isHazard: true)) == .high)
        }
        #expect(!hazardLabels.contains("person"))
    }

    @Test("a scooter is a vehicle: critical, and watched as it approaches from 25 m")
    func scooter() {
        #expect(DangerLevel(approaching: "scooter") == .critical)
        #expect(ApproachTuning.default.watchedLabels.contains("scooter"))
        #expect(ApproachTuning.default.vehicleMaximumDistance == 25)
    }
}
