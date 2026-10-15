import CoreGraphics
import ImageIO
import Testing
import Vision
@testable import SceneGeometry

@Suite("T5 — upright detections to depth-map coordinates")
struct DepthCoordinateMappingTests {
    private func expectClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1e-9) {
        #expect(abs(a.minX - b.minX) < tolerance, "\(a) vs \(b)")
        #expect(abs(a.minY - b.minY) < tolerance, "\(a) vs \(b)")
        #expect(abs(a.width - b.width) < tolerance, "\(a) vs \(b)")
        #expect(abs(a.height - b.height) < tolerance, "\(a) vs \(b)")
    }

    @Test("portrait: the upright left edge is the bottom of the landscape depth map")
    func portraitMapping() {
        // An upright box on the left of a portrait frame, vertically centred.
        let upright = CGRect(x: 0, y: 0.4, width: 0.2, height: 0.2)
        let sensor = CGImagePropertyOrientation.right.sensorRect(fromUpright: upright)
        expectClose(sensor, CGRect(x: 0.4, y: 0.8, width: 0.2, height: 0.2))
    }

    @Test("up is the identity")
    func identity() {
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        expectClose(CGImagePropertyOrientation.up.sensorRect(fromUpright: rect), rect)
    }

    /// Ground truth from Vision itself: draw a dark rectangle at a known place in a
    /// "sensor" image, let Vision find it with each orientation applied, and check that
    /// mapping Vision's upright result back lands on the rectangle that was drawn.
    @Test(
        "agrees with Vision for every orientation",
        arguments: [
            CGImagePropertyOrientation.up, .upMirrored, .down, .downMirrored,
            .left, .leftMirrored, .right, .rightMirrored,
        ]
    )
    func matchesVision(orientation: CGImagePropertyOrientation) throws {
        let width = 400, height = 300
        // Top-left-origin normalized rect of the drawn rectangle in the sensor image.
        let drawn = CGRect(x: 0.15, y: 0.2, width: 0.3, height: 0.45)

        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        // CGContext's origin is bottom-left.
        context.fill(CGRect(
            x: drawn.minX * CGFloat(width),
            y: (1 - drawn.maxY) * CGFloat(height),
            width: drawn.width * CGFloat(width),
            height: drawn.height * CGFloat(height)
        ))
        let image = try #require(context.makeImage())

        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.1
        request.maximumAspectRatio = 1
        request.minimumSize = 0.1
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        let observation = try #require(request.results?.first)

        let upright = normalizedUprightRect(fromVisionBox: observation.boundingBox)
        expectClose(orientation.sensorRect(fromUpright: upright), drawn, tolerance: 0.02)
    }
}
