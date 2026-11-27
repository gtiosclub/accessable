import CoreVideo
import Synchronization
import VideoToolbox

/// Copies camera images into buffers of its own, so work that outlives the frame never holds
/// one of ARKit's few camera buffers. Handles planar (camera YUV) and non-planar formats.
///
/// Copies come from a pool that allocates at most `allocationThreshold` buffers, so a slow
/// consumer can't make it grow. Once that many copies are alive, `copy` throws
/// `.poolExhausted` and the caller skips that frame.
final class PixelBufferCopier: Sendable {
    enum CopyError: Error, Equatable {
        case poolExhausted
        case allocationFailed(CVReturn)
        case copyFailed
        case scaleFailed(OSStatus)
    }

    static let allocationThreshold = 2

    private struct Key: Equatable {
        let width: Int
        let height: Int
        let format: OSType
    }

    private struct State {
        var pool: (key: Key, pool: CVPixelBufferPool)?
        var scaler: VTPixelTransferSession?
    }

    /// The size of every copy; nil keeps each source's own size.
    private let size: (width: Int, height: Int)?
    private let state = Mutex(State())

    /// `size`, when given, scales each copy (stretching, like Vision's `.scaleFill`).
    init(size: (width: Int, height: Int)? = nil) {
        self.size = size
    }

    /// A copy of `source`'s pixels in the same format, at `size` if one was given.
    func copy(_ source: CVPixelBuffer) throws(CopyError) -> CVPixelBuffer {
        let key = Key(
            width: size?.width ?? CVPixelBufferGetWidth(source),
            height: size?.height ?? CVPixelBufferGetHeight(source),
            format: CVPixelBufferGetPixelFormatType(source)
        )
        let pool = try pool(for: key)
        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: Self.allocationThreshold] as CFDictionary,
            &destination
        )
        if status == kCVReturnWouldExceedAllocationThreshold { throw .poolExhausted }
        guard status == kCVReturnSuccess, let destination else { throw .allocationFailed(status) }

        if size == nil {
            guard Self.copyPixels(from: source, to: destination) else { throw .copyFailed }
        } else {
            let status = VTPixelTransferSessionTransferImage(try scaler(), from: source, to: destination)
            guard status == noErr else { throw .scaleFailed(status) }
        }
        CVBufferPropagateAttachments(source, destination)
        return destination
    }

    /// The cached pool, replaced when the size or format changes.
    private func pool(for key: Key) throws(CopyError) -> CVPixelBufferPool {
        try state.withLock { state throws(CopyError) in
            if let cached = state.pool, cached.key == key { return cached.pool }
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: key.width,
                kCVPixelBufferHeightKey: key.height,
                kCVPixelBufferPixelFormatTypeKey: key.format,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            ]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            guard status == kCVReturnSuccess, let pool else { throw .allocationFailed(status) }
            state.pool = (key, pool)
            return pool
        }
    }

    private func scaler() throws(CopyError) -> VTPixelTransferSession {
        try state.withLock { state throws(CopyError) in
            if let scaler = state.scaler { return scaler }
            var session: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
            guard status == noErr, let session else { throw .scaleFailed(status) }
            state.scaler = session
            return session
        }
    }

    /// Copies every plane row by row, so differing row padding is handled. Both buffers must
    /// have the same size and format.
    static func copyPixels(from source: CVPixelBuffer, to destination: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        let planeCount = CVPixelBufferGetPlaneCount(source)
        if planeCount == 0 {
            return copyPlane(
                from: CVPixelBufferGetBaseAddress(source),
                sourceBytesPerRow: CVPixelBufferGetBytesPerRow(source),
                to: CVPixelBufferGetBaseAddress(destination),
                destinationBytesPerRow: CVPixelBufferGetBytesPerRow(destination),
                height: CVPixelBufferGetHeight(source)
            )
        }
        for plane in 0 ..< planeCount {
            guard copyPlane(
                from: CVPixelBufferGetBaseAddressOfPlane(source, plane),
                sourceBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                to: CVPixelBufferGetBaseAddressOfPlane(destination, plane),
                destinationBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(destination, plane),
                height: CVPixelBufferGetHeightOfPlane(source, plane)
            ) else { return false }
        }
        return true
    }

    private static func copyPlane(
        from source: UnsafeMutableRawPointer?,
        sourceBytesPerRow: Int,
        to destination: UnsafeMutableRawPointer?,
        destinationBytesPerRow: Int,
        height: Int
    ) -> Bool {
        guard let source, let destination, height > 0, sourceBytesPerRow > 0, destinationBytesPerRow > 0
        else { return false }
        let rowBytes = min(sourceBytesPerRow, destinationBytesPerRow)
        if sourceBytesPerRow == destinationBytesPerRow {
            memcpy(destination, source, height * sourceBytesPerRow)
        } else {
            for row in 0 ..< height {
                memcpy(
                    destination.advanced(by: row * destinationBytesPerRow),
                    source.advanced(by: row * sourceBytesPerRow),
                    rowBytes
                )
            }
        }
        return true
    }
}
