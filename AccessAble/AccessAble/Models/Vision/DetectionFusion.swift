import CoreGraphics

// Combining what the camera recognized with what the depth geometry found (1.1).
//
// A geometric obstacle (T11) knows exactly where something is and that it is in the way,
// but not what it is. A recognized object (T13, T14) knows what it is. When both describe
// the same thing, the user should hear "chair, 2 metres ahead" once — not "obstacle" plus
// a separate "chair".

/// Gives each geometric obstacle the label of the recognized object it overlaps most, and
/// removes those recognized objects so nothing is reported twice.
///
/// A match needs the two boxes' intersection to cover at least `minimumOverlap` of the
/// smaller box: the obstacle's box is projected from its footprint, so its shape differs
/// from a model's box even for the same object. Each recognized object labels at most one
/// obstacle. Matched obstacles keep their geometric distance and bearing.
///
/// - Returns: The labelled obstacles followed by the recognized objects left unmatched.
func fuse(
    obstacles: [Detection],
    recognized: [Detection],
    minimumOverlap: CGFloat = 0.5
) -> [Detection] {
    var candidates: [(overlap: CGFloat, obstacle: Int, object: Int)] = []
    for (obstacleIndex, obstacle) in obstacles.enumerated() {
        for (objectIndex, object) in recognized.enumerated() {
            let overlap = obstacle.boundingBox.overlapOfSmaller(with: object.boundingBox)
            if overlap >= minimumOverlap {
                candidates.append((overlap, obstacleIndex, objectIndex))
            }
        }
    }

    var labelled = obstacles
    var usedObstacles = Set<Int>()
    var usedObjects = Set<Int>()
    for candidate in candidates.sorted(by: { $0.overlap > $1.overlap })
    where !usedObstacles.contains(candidate.obstacle) && !usedObjects.contains(candidate.object) {
        usedObstacles.insert(candidate.obstacle)
        usedObjects.insert(candidate.object)
        labelled[candidate.obstacle].label = recognized[candidate.object].label
        labelled[candidate.obstacle].confidence = recognized[candidate.object].confidence
    }

    return labelled + recognized.indices.filter { !usedObjects.contains($0) }.map { recognized[$0] }
}
