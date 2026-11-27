import CoreVideo
import Foundation
import ImageIO
import Testing
@testable import AccessAble

struct ARFrameRetentionTests {
    /// A small BGRA buffer owned by the test; not from ARKit's pool.
    private func makeBuffer(width: Int = 8, height: Int = 8) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary,
            &buffer
        )
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
        return buffer!
    }

    @Test
    func pixelBufferCopyIsIndependentOfSource() throws {
        let source = makeBuffer()
        CVPixelBufferLockBaseAddress(source, [])
        let src = CVPixelBufferGetBaseAddress(source)!
        memset(src, 0xAB, CVPixelBufferGetBytesPerRow(source) * CVPixelBufferGetHeight(source))
        CVPixelBufferUnlockBaseAddress(source, [])

        let copy = try #require(PixelBufferCopy.copy(source))
        #expect(copy !== source)

        CVPixelBufferLockBaseAddress(source, [])
        memset(CVPixelBufferGetBaseAddress(source)!, 0x00, 4)
        CVPixelBufferUnlockBaseAddress(source, [])

        CVPixelBufferLockBaseAddress(copy, .readOnly)
        let byte = CVPixelBufferGetBaseAddress(copy)!.assumingMemoryBound(to: UInt8.self).pointee
        CVPixelBufferUnlockBaseAddress(copy, .readOnly)
        #expect(byte == 0xAB)
    }

    @Test
    func textReaderDoesNotRetainSourceBufferAfterReadIfDueReturns() {
        let reader = TextReader(interval: 0)
        let source = makeBuffer()
        // Keep an extra retain so we can compare counts after the call returns.
        let kept = Unmanaged.passRetained(source)
        defer { kept.release() }
        let before = CFGetRetainCount(source)

        reader.readIfDue(source, orientation: .up, at: 1)

        #expect(CFGetRetainCount(source) == before)
        #expect(reader.isReading)
    }

    @Test
    func surfaceReaderDoesNotRetainSourceBufferAfterReadIfDueReturns() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("surface-retention-\(UUID().uuidString).mlmodelc")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let reader = SurfaceReader(compiledModelURL: temp, interval: 0)
        let source = makeBuffer()
        let kept = Unmanaged.passRetained(source)
        defer { kept.release() }
        let before = CFGetRetainCount(source)

        reader.readIfDue(source, orientation: .up, at: 1)

        #expect(CFGetRetainCount(source) == before)
    }

    @Test
    func firstFrameUnsubscribesBeforeReturning() async {
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
        continuation.yield(7)
        continuation.finish()

        var unsubscribed = false
        let value = await FirstFrame.take(stream) { unsubscribed = true }

        #expect(value == 7)
        #expect(unsubscribed)
    }
}
