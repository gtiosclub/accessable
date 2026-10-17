import ImageIO
import UIKit

extension CGImagePropertyOrientation {
    /// How the rear camera's `ARFrame.capturedImage` must be rotated to appear upright when
    /// the interface is in `interfaceOrientation`. Owner: Computer Vision (1.4 / task T4).
    ///
    /// ARKit delivers the image in the sensor's landscape-right orientation, so a portrait
    /// interface needs `.right`. Pass the result to `VNImageRequestHandler` so Vision returns
    /// upright boxes, and to `sensorRect(fromUpright:)` to map them back into the depth map.
    /// Rear camera only: the front camera is mirrored.
    init(cameraImageIn interfaceOrientation: UIInterfaceOrientation) {
        self = switch interfaceOrientation {
        case .portraitUpsideDown: .left
        case .landscapeLeft: .down
        case .landscapeRight: .up
        default: .right
        }
    }
}
