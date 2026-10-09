import CoreGraphics
import Foundation

// Converting Vision's human-rectangle results into the app's shared `Detection`
// (1.1 / task T14). Kept free of any Vision import so the coordinate handling — the part
// that is easy to get silently wrong — can be unit-tested with plain structs.

/// Anything shaped like a Vision rectangle observation.
///
/// `VNHumanObservation` satisfies this as-is (`boundingBox` comes from its
/// `VNDetectedObjectObservation` superclass, and `VNConfidence` is a `Float`), so the
/// conformance costs nothing and tests can supply their own stand-ins.
protocol HumanRectangleObservation {
    /// Normalized 0...1 with the origin at BOTTOM-LEFT, which is Vision's convention.
    var boundingBox: CGRect { get }
    var confidence: Float { get }
}

/// Converts Vision's bottom-left-origin box into the top-left-origin box that
/// `Detection.boundingBox` is documented to hold, clamped to the frame.
///
/// Only the Y axis needs flipping: `VNImageRequestHandler(cvPixelBuffer:orientation:)`
/// has already applied the orientation, so the box arrives in upright image space. If
/// boxes ever come out rotated, that assumption is where to look first.
func normalizedUprightRect(fromVisionBox box: CGRect) -> CGRect {
    func clamped(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }

    // Vision occasionally returns boxes a little outside the frame for a person who is
    // partly out of shot.
    let minX = clamped(box.minX)
    let maxX = clamped(box.maxX)
    let minY = clamped(1 - box.maxY)
    let maxY = clamped(1 - box.minY)

    return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
}

/// Maps Vision observations onto the shared `Detection` type, dropping anything below
/// `minimumConfidence`. Results come back in descending confidence order.
///
/// `distance` and `bearing` are left nil: filling them in needs the depth frame, which is
/// a different module's job. `isHazard` is false because the repo defines a hazard as
/// something you could walk into or fall off — a person is a moving collision risk, which
/// the geometric corridor logic handles, not a fall hazard.
func personDetections(
    from observations: [any HumanRectangleObservation],
    minimumConfidence: Float = 0.5
) -> [Detection] {
    observations
        .filter { $0.confidence >= minimumConfidence }
        .sorted { $0.confidence > $1.confidence }
        .map { observation in
            Detection(
                label: "person",
                confidence: observation.confidence,
                boundingBox: normalizedUprightRect(fromVisionBox: observation.boundingBox),
                origin: .model,
                isHazard: false
            )
        }
}
