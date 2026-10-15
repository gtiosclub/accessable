import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import SceneGeometry

@Suite("T17 - Text Recognition")
struct TextDetectorTests {
    
    @Test("A blank image returns no recognized text")
    func blankImage() throws {
        let width = 128
        let height = 128
        
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        
        context.setFillColor(
            CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        )
        
        context.fill(
            CGRect(x: 0, y: 0, width: width, height: height)
        )
        
        let image = try #require(context.makeImage())
        
        #expect(
            try TextDetector()
                .detectText(cgImage: image)
                .isEmpty
        )
    }
    
    @Test("Recognizes text from a saved room sign")
    func recognizesRoomSign() throws {
        let imageURL = try #require(
            Bundle.module.url(
                forResource: "room210",
                withExtension: "jpg"
            )
        )
        
        let source = try #require(
            CGImageSourceCreateWithURL(
                imageURL as CFURL,
                nil
            )
        )
        
        let image = try #require(
            CGImageSourceCreateImageAtIndex(
                source,
                0,
                nil
            )
        )
        
        let results = try TextDetector().detectText(
            cgImage: image
        )
        
        let recognizedString = results
            .map{ $0.string }
            .joined(separator: " ")
            .lowercased()
        
        #expect(recognizedString.contains("room"))
        #expect(recognizedString.contains("210"))
    }
}
