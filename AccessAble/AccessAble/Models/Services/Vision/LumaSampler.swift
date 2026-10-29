import CoreGraphics
import CoreVideo
import ImageIO

/// Samples the brightness (Y) plane of ARKit's camera image into a small upright grid for
/// the crosswalk check (T37). Nearest-pixel sampling is plenty for finding stripes.
func uprightLumaGrid(
    from image: CVPixelBuffer,
    orientation: CGImagePropertyOrientation,
    width: Int,
    height: Int
) -> LumaGrid? {
    guard width > 0, height > 0, CVPixelBufferIsPlanar(image) else { return nil }
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }

    guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { return nil }
    let planeWidth = CVPixelBufferGetWidthOfPlane(image, 0)
    let planeHeight = CVPixelBufferGetHeightOfPlane(image, 0)
    let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
    let pixels = base.assumingMemoryBound(to: UInt8.self)

    var values = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let upright = CGPoint(x: (Double(x) + 0.5) / Double(width), y: (Double(y) + 0.5) / Double(height))
            let sensor = orientation.sensorPoint(fromUpright: upright)
            let px = min(Int(sensor.x * Double(planeWidth)), planeWidth - 1)
            let py = min(Int(sensor.y * Double(planeHeight)), planeHeight - 1)
            values[y * width + x] = pixels[py * bytesPerRow + px]
        }
    }
    return LumaGrid(width: width, height: height, values: values)
}
