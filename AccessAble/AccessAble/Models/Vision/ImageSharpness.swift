import CoreVideo
import Foundation

func imageSharpnessScore(_ pixelBuffer: CVPixelBuffer) -> Float? {
    guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0 else {
        return nil
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
    }

    guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
        return nil
    }

    let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
    let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

    guard width > 1, height > 1 else {
        return nil
    }

    let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)

    let sampleStep = 8
    var differenceTotal = 0
    var sampleCount = 0

    for y in stride(from: 1, to: height, by: sampleStep) {
        for x in stride(from: 1, to: width, by: sampleStep) {
            let current = Int(pixels[y * bytesPerRow + x])
            let left = Int(pixels[y * bytesPerRow + x - 1])
            let above = Int(pixels[(y - 1) * bytesPerRow + x])

            differenceTotal += abs(current - left)
            differenceTotal += abs(current - above)
            sampleCount += 2
        }
    }

    guard sampleCount > 0 else {
        return nil
    }

    return Float(differenceTotal) / Float(sampleCount)
}
