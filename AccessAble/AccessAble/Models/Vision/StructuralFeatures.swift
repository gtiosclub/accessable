import Foundation
import simd

// T36: doors and windows from ARKit's classified scene mesh (LiDAR devices only).
// ARKit labels each mesh triangle; nearby triangles with the same label are grouped into
// one feature so a door is one thing, not a few hundred triangles.

/// Centre of one classified mesh triangle, in world coordinates.
struct MeshFaceSample: Sendable {
    let label: String
    let position: SIMD3<Float>
}

struct StructuralFeature: Sendable, Equatable {
    let label: String
    var center: SIMD3<Float>
    var faceCount: Int
}

/// Groups samples of the same label within `mergeDistance` of a group's centre. Groups
/// with fewer than `minimumFaces` triangles are dropped as misclassified patches.
func structuralFeatures(
    from samples: [MeshFaceSample],
    mergeDistance: Float = 1.5,
    minimumFaces: Int = 30
) -> [StructuralFeature] {
    var groups: [StructuralFeature] = []
    for sample in samples {
        if let i = groups.firstIndex(where: {
            $0.label == sample.label && simd_distance($0.center, sample.position) < mergeDistance
        }) {
            let n = Float(groups[i].faceCount)
            groups[i].center = (groups[i].center * n + sample.position) / (n + 1)
            groups[i].faceCount += 1
        } else {
            groups.append(StructuralFeature(label: sample.label, center: sample.position, faceCount: 1))
        }
    }
    return groups.filter { $0.faceCount >= minimumFaces }
}
