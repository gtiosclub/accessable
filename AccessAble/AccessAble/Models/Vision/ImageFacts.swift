import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Vision

/// What on-device vision found in one still image and around it: the only thing the Ask AI
/// model (T19) learns about the scene. Owner: Computer Vision (1.3 / task T19).
struct ImageFacts: Equatable, Sendable {
    /// Objects and people from the live pipeline (T13/T14), hazards then nearest first,
    /// with direction and, on LiDAR devices, distance. What "Describe my surroundings" uses.
    var detections: [Detection] = []
    /// Kerbs, steps and drop-offs from the live pipeline (T12).
    var elevationHazards: [ElevationHazard] = []
    /// Each detection's main colour in the still, by `Detection.id`, e.g. "teal".
    /// A rough estimate; see `ImageFactExtractor.colors(of:in:orientation:)`.
    var detectionColors: [UUID: String] = [:]
    /// Text in reading order, boxes upright and top-left-origin.
    var text: [RecognizedText] = []
    /// What the scene probably contains, most confident first, e.g. "door", "chair".
    /// Whole-image classification, so these have no position.
    var labels: [String] = []
    /// People, as upright top-left-origin boxes.
    var people: [CGRect] = []

    var isEmpty: Bool {
        detections.isEmpty && elevationHazards.isEmpty && text.isEmpty && labels.isEmpty && people.isEmpty
    }
}

/// Reads `ImageFacts` out of a still image with Apple's Vision framework, on the device.
///
/// Text comes from `TextDetector` (T17) run on the still image; this does not touch the
/// live OCR pipeline. Each list is capped so the facts stay well inside the on-device
/// model's 4K-token context.
struct ImageFactExtractor: Sendable {
    var textDetector = TextDetector()
    /// Scene labels below this are dropped; the classifier reports many weak guesses.
    var minimumLabelConfidence: Float = 0.3
    var maxLabels = 6
    var maxTextItems = 12

    /// Decodes `imageData` (JPEG, PNG, HEIC…) and honours its EXIF orientation. Also
    /// estimates the colour of each of `detections`, whose boxes are upright.
    func facts(from imageData: Data, colorsFor detections: [Detection] = []) throws -> ImageFacts {
        guard !imageData.isEmpty,
              let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw AskAIError.invalidImage }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        var facts = try facts(from: image, orientation: orientation)
        facts.detectionColors = colors(of: detections, in: image, orientation: orientation)
        return facts
    }

    func facts(from image: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> ImageFacts {
        let classification = VNClassifyImageRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([classification, humans])

        var labels: [String] = []
        for observation in classification.results ?? [] where observation.confidence >= minimumLabelConfidence {
            // "chair_other" → "chair", "street_sign" → "street sign".
            let label = observation.identifier
                .replacingOccurrences(of: "_other", with: "")
                .replacingOccurrences(of: "_", with: " ")
            if !labels.contains(label) { labels.append(label) }
        }

        return ImageFacts(
            text: Array(try textDetector.detectText(cgImage: image, orientation: orientation).prefix(maxTextItems)),
            labels: Array(labels.prefix(maxLabels)),
            people: (humans.results ?? []).map { normalizedUprightRect(fromVisionBox: $0.boundingBox) }
        )
    }
}

extension ImageFactExtractor {
    /// The most common colour name in the middle half of each detection's box: the middle
    /// keeps out most of the background, and counting names rather than averaging keeps a
    /// two-tone object from turning into a colour it doesn't have. Boxes from the live
    /// pipeline are a frame or two older than the still, so this is an estimate.
    func colors(
        of detections: [Detection],
        in image: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> [UUID: String] {
        var colors: [UUID: String] = [:]
        for detection in detections {
            let box = detection.boundingBox
            let middle = orientation.sensorRect(fromUpright: box.insetBy(dx: box.width / 4, dy: box.height / 4))
            if let name = dominantColorName(in: image, normalizedRect: middle) {
                colors[detection.id] = name
            }
        }
        return colors
    }

    private func dominantColorName(in image: CGImage, normalizedRect rect: CGRect) -> String? {
        let pixels = CGRect(
            x: rect.minX * CGFloat(image.width), y: rect.minY * CGFloat(image.height),
            width: rect.width * CGFloat(image.width), height: rect.height * CGFloat(image.height)
        ).integral
        guard pixels.width >= 1, pixels.height >= 1,
              let region = image.cropping(to: pixels),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        // 16 × 16 samples are plenty to find the main colour.
        let side = 16
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(region, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var counts: [String: Int] = [:]
        for pixel in stride(from: 0, to: bytes.count, by: 4) {
            let name = colorName(
                red: Double(bytes[pixel]) / 255, green: Double(bytes[pixel + 1]) / 255, blue: Double(bytes[pixel + 2]) / 255
            )
            counts[name, default: 0] += 1
        }
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
    }
}

/// A plain colour name for an sRGB colour (components 0...1), as a person would say it.
func colorName(red: Double, green: Double, blue: Double) -> String {
    let brightest = max(red, green, blue)
    let range = brightest - min(red, green, blue)
    let saturation = brightest == 0 ? 0 : range / brightest

    if brightest < 0.2 { return "black" }
    if saturation < 0.2 { return brightest > 0.85 ? "white" : "gray" }

    var hue: Double = switch brightest {
    case red: 60 * ((green - blue) / range)
    case green: 60 * ((blue - red) / range + 2)
    default: 60 * ((red - green) / range + 4)
    }
    if hue < 0 { hue += 360 }

    return switch hue {
    case 15 ..< 45: brightest < 0.6 ? "brown" : "orange"
    case 45 ..< 70: brightest < 0.5 ? "brown" : "yellow"
    case 70 ..< 165: "green"
    case 165 ..< 200: "teal"
    case 200 ..< 255: "blue"
    case 255 ..< 290: "purple"
    case 290 ..< 345: "pink"
    default: "red"
    }
}

/// Encodes a camera frame as an upright JPEG still for Ask AI. `orientation` is how the
/// buffer is rotated relative to upright, as for Vision (T4).
func stillImageJPEG(
    from pixelBuffer: CVPixelBuffer,
    orientation: CGImagePropertyOrientation,
    quality: Double = 0.8
) throws -> Data {
    let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let data = CIContext().jpegRepresentation(
              of: image,
              colorSpace: colorSpace,
              options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
          )
    else { throw AskAIError.invalidImage }
    return data
}
