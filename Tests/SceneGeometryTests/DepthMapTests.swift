import CoreVideo
import Testing
@testable import SceneGeometry

@Suite("T6 — depth filtering")
struct DepthMapTests {
    private func pixelBuffer<T>(
        width: Int, height: Int, format: OSType, value: (Int, Int) -> T
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format, nil, &buffer)
        let result = try #require(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(result))
        let rowBytes = CVPixelBufferGetBytesPerRow(result)
        for row in 0 ..< height {
            let pointer = base.advanced(by: row * rowBytes).assumingMemoryBound(to: T.self)
            for column in 0 ..< width {
                pointer[column] = value(column, row)
            }
        }
        return result
    }

    @Test("keeps confident readings in range and drops everything else")
    func filtersReadings() throws {
        // Columns: 0 too close, 1 in range, 2 too far, 3 no return, 4 in range but low confidence.
        let readings: [Float32] = [0.05, 1.5, 25, .nan, 2.0]
        let depth = try pixelBuffer(width: 5, height: 2, format: kCVPixelFormatType_DepthFloat32) { column, _ in
            readings[column]
        }
        let confidence = try pixelBuffer(width: 5, height: 2, format: kCVPixelFormatType_OneComponent8) { column, _ in
            UInt8(column == 4 ? 0 : 2)
        }

        let map = try #require(DepthMap(depth: depth, confidence: confidence))

        #expect(map.width == 5 && map.height == 2)
        for row in 0 ..< 2 {
            #expect(map[0, row] == nil)
            #expect(map[1, row] == 1.5)
            #expect(map[2, row] == nil)
            #expect(map[3, row] == nil)
            #expect(map[4, row] == nil)
        }
    }

    @Test("without a confidence map only range and finiteness are checked")
    func noConfidenceMap() throws {
        let depth = try pixelBuffer(width: 3, height: 1, format: kCVPixelFormatType_DepthFloat32) { column, _ in
            Float32(column + 1)
        }
        let map = try #require(DepthMap(depth: depth, confidence: nil))
        #expect(map[0, 0] == 1 && map[1, 0] == 2 && map[2, 0] == 3)
    }

    @Test("rejects buffers in the wrong format or size")
    func rejectsMismatchedBuffers() throws {
        let depth = try pixelBuffer(width: 4, height: 4, format: kCVPixelFormatType_DepthFloat32) { _, _ in Float32(1) }
        let smallConfidence = try pixelBuffer(width: 2, height: 2, format: kCVPixelFormatType_OneComponent8) { _, _ in UInt8(2) }
        let notDepth = try pixelBuffer(width: 4, height: 4, format: kCVPixelFormatType_OneComponent8) { _, _ in UInt8(1) }

        #expect(DepthMap(depth: depth, confidence: smallConfidence) == nil)
        #expect(DepthMap(depth: notDepth, confidence: nil) == nil)
    }

    @Test("out-of-bounds reads return nil")
    func outOfBounds() {
        let map = DepthMap.uniform(1, width: 2, height: 2)
        #expect(map[-1, 0] == nil)
        #expect(map[2, 0] == nil)
        #expect(map[0, 2] == nil)
        #expect(map[1, 1] == 1)
    }
}
