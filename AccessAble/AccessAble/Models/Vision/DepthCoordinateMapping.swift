import CoreGraphics
import ImageIO

// Mapping detections from the upright image into the depth map (1.1 / task T5).
//
// Detection boxes are normalized, top-left origin, in the upright image Vision saw after
// applying the frame's orientation. ARKit's captured image and LiDAR depth map are both in
// the sensor's own landscape orientation and cover the same field of view, so a normalized
// sensor coordinate addresses the same spot in either, whatever their resolutions.
// Converting upright to sensor coordinates is therefore the whole job — a plain rescale
// without undoing the rotation would sample the wrong part of the scene.

extension CGImagePropertyOrientation {
    /// The normalized sensor-image point (top-left origin) that appears at `point` in the
    /// upright image produced by applying this orientation.
    func sensorPoint(fromUpright point: CGPoint) -> CGPoint {
        let (u, v) = (point.x, point.y)
        return switch self {
        case .up: CGPoint(x: u, y: v)
        case .upMirrored: CGPoint(x: 1 - u, y: v)
        case .down: CGPoint(x: 1 - u, y: 1 - v)
        case .downMirrored: CGPoint(x: u, y: 1 - v)
        case .leftMirrored: CGPoint(x: v, y: u)
        case .right: CGPoint(x: v, y: 1 - u)
        case .rightMirrored: CGPoint(x: 1 - v, y: 1 - u)
        case .left: CGPoint(x: 1 - v, y: u)
        }
    }

    /// `rect` from the upright image, expressed in normalized sensor coordinates.
    func sensorRect(fromUpright rect: CGRect) -> CGRect {
        let a = sensorPoint(fromUpright: CGPoint(x: rect.minX, y: rect.minY))
        let b = sensorPoint(fromUpright: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
