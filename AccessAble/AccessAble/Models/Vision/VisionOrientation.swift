import CoreGraphics
import ImageIO
import UIKit

// FLAG (judgment call): this mapping assumes the rear-facing camera, which is the only camera
// this app uses for guidance. The front camera's sensor is mounted mirrored relative to the
// rear one, so the same switch would need different (mirrored) cases if a front-camera path is
// ever added — ping CV subteam before reusing this for anything but ARFrame/rear capture.
/// Maps the current interface orientation to the orientation Vision needs to correctly
/// interpret bounding boxes and recognized text in a `CVPixelBuffer` captured from the
/// rear-facing camera (the only camera this app uses for guidance).
///
/// Pass the result to `VNImageRequestHandler(cvPixelBuffer:orientation:options:)` alongside
/// the pixel buffer from `ARFrame.capturedImage`.
func visionOrientation(interfaceOrientation: UIInterfaceOrientation) -> CGImagePropertyOrientation {
    switch interfaceOrientation {
    case .portrait:
        return .right
    case .portraitUpsideDown:
        return .left
    case .landscapeLeft:
        return .down
    case .landscapeRight:
        return .up
    case .unknown:
        return .right
    @unknown default:
        return .right
    }
}

/// Converts between Vision's normalized coordinate system (origin bottom-left, y up) and the
/// app's convention for normalized geometry (origin top-left, y down — the same convention
/// documented on `Detection.boundingBox`), plus conversion to/from pixel coordinates in an
/// image of a given size.
enum VisionCoordinates {
    /// Vision-normalized point → app-normalized point. Flipping is its own inverse, so the
    /// same function converts in both directions.
    static func flipped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: 1 - point.y)
    }

    /// Vision-normalized rect → app-normalized rect (origin top-left). Also its own inverse:
    /// pass an app-normalized rect in to get the equivalent Vision-normalized rect back out.
    static func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    /// App-normalized (origin top-left) point → pixel coordinates in an image of `size`.
    static func point(_ point: CGPoint, inImageOfSize size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    /// App-normalized (origin top-left) rect → pixel coordinates in an image of `size`.
    static func rect(_ rect: CGRect, inImageOfSize size: CGSize) -> CGRect {
        CGRect(
            x: rect.minX * size.width,
            y: rect.minY * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        )
    }
}
