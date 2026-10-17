import CoreGraphics

// Combining what the camera recognized with what the depth geometry found (1.1).
//
// A geometric obstacle (T11) knows exactly where something is and that it is in the way,
// but not what it is. A recognized object (T13, T14) knows what it is. When both describe
// the same thing, the user should hear "chair, 2 metres ahead" once — not "obstacle" plus
// a separate "chair".

/// Labels a geometric obstacle may take from a recognized object: things that stand on
/// the floor and can be walked into. A cup, a laptop or a phone the model spots on a desk
/// must not rename the desk.
let fusableLabels: Set<String> = hazardLabels.union(["person"])

/// Gives each geometric obstacle the label of the recognized object it overlaps most, and
/// removes those recognized objects so nothing is reported twice.
///
/// A match needs all of:
/// - the boxes' intersection to cover at least `minimumOverlap` of the smaller box: the
///   obstacle's box is projected from its footprint, so its shape differs from a model's
///   box even for the same object;
/// - the intersection to cover at least `minimumOverlapOfLarger` of the larger box, so a
///   person seen past a chair does not become the chair's label just because their box
///   lands inside its projected box;
/// - distances, where both are known, to agree within `distanceTolerance` or a quarter
///   of the nearer one. The depth under a model box is the real test of "same thing".
///
/// Each recognized object labels at most one obstacle. Matched obstacles keep their
/// geometric distance and bearing. Only `fusableLabels` are transferred.
///
/// - Returns: The labelled obstacles followed by the recognized objects left unmatched.
func fuse(
    obstacles: [Detection],
    recognized: [Detection],
    minimumOverlap: CGFloat = 0.5,
    minimumOverlapOfLarger: CGFloat = 0.2,
    distanceTolerance: Double = 0.5
) -> [Detection] {
    var candidates: [(overlap: CGFloat, obstacle: Int, object: Int)] = []
    for (obstacleIndex, obstacle) in obstacles.enumerated() {
        for (objectIndex, object) in recognized.enumerated() where fusableLabels.contains(object.label) {
            let overlap = obstacle.boundingBox.overlapOfSmaller(with: object.boundingBox)
            guard overlap >= minimumOverlap,
                  obstacle.boundingBox.overlapOfLarger(with: object.boundingBox) >= minimumOverlapOfLarger
            else { continue }
            if let a = obstacle.distance, let b = object.distance,
               abs(a - b) > max(distanceTolerance, 0.25 * min(a, b)) {
                continue
            }
            candidates.append((overlap, obstacleIndex, objectIndex))
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
