import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import SceneGeometry

@Suite("T7 — detection bounding-box distance")
struct DetectionDistanceEstimatorTests {
    @Test("reports the median depth and sample count inside the box")
    func medianDistance() throws {
        let buffer = try depthMap(width: 10, height: 8, filling: 4)
        setDepth(1.84, in: buffer, columns: 2 ..< 6, rows: 2 ..< 6)

        let estimate = try #require(estimateDistance(
            boundingBox: CGRect(x: 0.2, y: 0.25, width: 0.4, height: 0.5),
            depthMap: buffer
        ))

        #expect(abs(estimate.meters - 1.84) < 1e-6)
        #expect(estimate.validSampleCount == 16)
        #expect(estimate.spread == 0)
    }

    @Test("rejects isolated extreme readings before measuring distance")
    func rejectsOutliers() throws {
        let buffer = try depthMap(width: 8, height: 8, filling: 1.8)
        setDepth(0.25, in: buffer, columns: 0 ..< 1, rows: 0 ..< 1)
        setDepth(5.5, in: buffer, columns: 7 ..< 8, rows: 7 ..< 8)

        let estimate = try #require(estimateDistance(
            boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), depthMap: buffer
        ))

        #expect(abs(estimate.meters - 1.8) < 1e-6)
        #expect(estimate.validSampleCount == 62)
        #expect(estimate.spread == 0)
    }

    @Test("drops invalid readings without letting them propagate")
    func filtersInvalidDepth() throws {
        let buffer = try depthMap(width: 4, height: 4, filling: 2)
        setDepth(.nan, in: buffer, columns: 0 ..< 1, rows: 0 ..< 1)
        setDepth(0, in: buffer, columns: 1 ..< 2, rows: 0 ..< 1)
        setDepth(.infinity, in: buffer, columns: 2 ..< 3, rows: 0 ..< 1)

        let estimate = try #require(estimateDistance(
            boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), depthMap: buffer
        ))

        #expect(estimate.validSampleCount == 13)
        #expect(estimate.meters == 2)
    }

    @Test("returns nil when too few usable readings remain")
    func insufficientSamples() throws {
        let buffer = try depthMap(width: 4, height: 4, filling: .nan)
        setDepth(1.5, in: buffer, columns: 0 ..< 3, rows: 0 ..< 1)

        #expect(estimateDistance(
            boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), depthMap: buffer
        ) == nil)
    }

    @Test("clips an out-of-frame box to valid depth-map pixels")
    func clipsBoundingBox() throws {
        let buffer = try depthMap(width: 10, height: 8, filling: 1.2)
        var tuning = DistanceEstimationTuning.default
        tuning.minimumValidSampleCount = 1

        let estimate = try #require(estimateDistance(
            boundingBox: CGRect(x: -0.2, y: 0.75, width: 0.4, height: 0.5),
            depthMap: buffer,
            tuning: tuning
        ))

        #expect(estimate.validSampleCount == 4)
        #expect(estimate.meters == 1.2)
    }

    @Test("reports interquartile spread after outlier removal")
    func reportsSpread() throws {
        let buffer = try depthMap(
            width: 4,
            height: 4,
            values: [
                1.6, 1.7, 1.8, 1.9,
                1.6, 1.7, 1.8, 1.9,
                1.6, 1.7, 1.8, 1.9,
                1.6, 1.7, 1.8, 1.9,
            ]
        )

        let estimate = try #require(estimateDistance(
            boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), depthMap: buffer
        ))

        #expect(abs(estimate.meters - 1.75) < 1e-6)
        #expect(abs(estimate.spread - 0.15) < 1e-6)
    }

    private func depthMap(width: Int, height: Int, filling value: Float) throws -> CVPixelBuffer {
        try depthMap(width: width, height: height, values: Array(repeating: value, count: width * height))
    }

    private func depthMap(width: Int, height: Int, values: [Float]) throws -> CVPixelBuffer {
        #expect(values.count == width * height)
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_DepthFloat32,
            nil,
            &pixelBuffer
        )
        #expect(result == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)

        setDepthValues(values, in: buffer)
        return buffer
    }

    private func setDepth(_ value: Float, in buffer: CVPixelBuffer, columns: Range<Int>, rows: Range<Int>) {
        precondition(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        for row in rows {
            for column in columns {
                baseAddress
                    .advanced(by: row * bytesPerRow + column * MemoryLayout<Float32>.stride)
                    .assumingMemoryBound(to: Float32.self)
                    .pointee = value
            }
        }
    }

    private func setDepthValues(_ values: [Float], in buffer: CVPixelBuffer) {
        precondition(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        for (index, value) in values.enumerated() {
            let row = index / width
            let column = index % width
            baseAddress
                .advanced(by: row * bytesPerRow + column * MemoryLayout<Float32>.stride)
                .assumingMemoryBound(to: Float32.self)
                .pointee = value
        }
    }
}
