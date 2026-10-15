import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SceneGeometry

@Suite("T17 — text recognition")
struct TextDetectorTests {
    @Test("a blank image returns no text")
    func blankImage() throws {
        let context = try #require(CGContext(
            data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        let image = try #require(context.makeImage())

        #expect(try TextDetector().detectText(cgImage: image).isEmpty)
    }

    @Test("reads a saved room sign")
    func readsRoomSign() throws {
        let url = try #require(Bundle.module.url(forResource: "room210", withExtension: "jpg"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        let text = try TextDetector().detectText(cgImage: image).map(\.string).joined(separator: " ").lowercased()

        #expect(text.contains("room"))
        #expect(text.contains("210"))
    }
}

@Suite("T17 — de-duplicating text across reads")
struct RecognizedTextMemoryTests {
    private func text(_ string: String, confidence: Float = 0.9) -> RecognizedText {
        RecognizedText(string: string, confidence: confidence, boundingBox: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.1))
    }

    @Test("the same sign read repeatedly is reported once")
    func deduplicates() {
        var memory = RecognizedTextMemory()
        memory.record([text("Room 210")], at: 0)
        memory.record([text("ROOM  210"), text("Exit", confidence: 0.95)], at: 1)

        #expect(memory.current(at: 1).map(\.string) == ["Exit", "ROOM  210"])
    }

    @Test("text not read again within the retention window is forgotten")
    func forgets() {
        var memory = RecognizedTextMemory()
        memory.retention = 2
        memory.record([text("Room 210")], at: 0)

        #expect(memory.current(at: 1.5).count == 1)
        #expect(memory.current(at: 2.5).isEmpty)
    }
}
