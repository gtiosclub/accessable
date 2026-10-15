import CoreVideo
import Foundation

/// One frame of LiDAR depth with the readings that shouldn't be trusted already removed.
/// Owner: Computer Vision (1.1 / tasks T2, T6).
///
/// Values are metres along the camera's optical axis, row-major from the top-left of the
/// map in sensor orientation (landscape, as ARKit delivers it). An unreliable pixel holds
/// NaN, so the point cloud and object distances read the same filtered data and neither
/// re-implements the rules.
///
/// The map is copied out of ARKit's buffers once per frame. At 256x192 that is about
/// 200 KB and far cheaper than locking the buffer per read, and it leaves a plain value
/// that tests can build directly.
struct DepthMap: Sendable {
    let width: Int
    let height: Int
    let values: [Float]

    init(width: Int, height: Int, values: [Float]) {
        precondition(width >= 0 && height >= 0 && values.count == width * height, "DepthMap size mismatch")
        self.width = width
        self.height = height
        self.values = values
    }

    /// The filtered depth at a pixel, or nil if it is out of bounds or unreliable.
    subscript(column: Int, row: Int) -> Float? {
        guard column >= 0, column < width, row >= 0, row < height else { return nil }
        let value = values[row * width + column]
        return value.isNaN ? nil : value
    }
}

/// Which raw LiDAR readings `DepthMap` keeps.
struct DepthFilter: Sendable {
    /// Readings outside this range, in metres, are dropped. Below the near limit is usually
    /// the user's own hand or body; beyond the far limit LiDAR returns are too sparse and
    /// noisy to cluster.
    var validRange: ClosedRange<Float> = 0.2 ... 6.0
    /// Lowest accepted `ARConfidenceLevel` raw value: 0 low, 1 medium, 2 high.
    /// Low-confidence returns are the main source of phantom obstacles.
    var minimumConfidence: UInt8 = 1

    static let `default` = DepthFilter()

    init() {}
}

extension DepthMap {
    /// Copies and filters ARKit depth data (`ARDepthData.depthMap` and `.confidenceMap`).
    ///
    /// Returns nil when `depth` is not a 32-bit float buffer, when `confidence` is not an
    /// 8-bit buffer of the same size, or when a buffer can't be read.
    init?(depth: CVPixelBuffer, confidence: CVPixelBuffer?, filter: DepthFilter = .default) {
        guard CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32 else { return nil }
        let width = CVPixelBufferGetWidth(depth)
        let height = CVPixelBufferGetHeight(depth)
        if let confidence {
            guard CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8,
                  CVPixelBufferGetWidth(confidence) == width,
                  CVPixelBufferGetHeight(confidence) == height
            else { return nil }
        }

        guard CVPixelBufferLockBaseAddress(depth, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        if let confidence {
            guard CVPixelBufferLockBaseAddress(confidence, .readOnly) == kCVReturnSuccess else { return nil }
        }
        defer {
            if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depth)

        let confidenceBase = confidence.flatMap(CVPixelBufferGetBaseAddress)
        let confidenceRowBytes = confidence.map(CVPixelBufferGetBytesPerRow) ?? 0
        if confidence != nil, confidenceBase == nil { return nil }

        var values = [Float](repeating: .nan, count: width * height)
        for row in 0 ..< height {
            let depthRow = depthBase.advanced(by: row * depthRowBytes).assumingMemoryBound(to: Float32.self)
            let confidenceRow = confidenceBase?.advanced(by: row * confidenceRowBytes).assumingMemoryBound(to: UInt8.self)
            for column in 0 ..< width {
                let value = depthRow[column]
                guard value.isFinite, filter.validRange.contains(value) else { continue }
                if let confidenceRow, confidenceRow[column] < filter.minimumConfidence { continue }
                values[row * width + column] = value
            }
        }
        self.init(width: width, height: height, values: values)
    }
}
