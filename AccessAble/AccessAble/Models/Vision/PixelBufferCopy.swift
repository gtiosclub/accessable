import CoreVideo
import Foundation

/// Takes the first value from a stream and runs `onFirst` before returning it, so callers can
/// unsubscribe (or otherwise release upstream resources) before doing slow work on the value.
enum FirstFrame {
    static func take<T>(_ stream: AsyncStream<T>, onFirst: () -> Void) async -> T? {
        for await value in stream {
            onFirst()
            return value
        }
        return nil
    }
}

/// Deep-copies a `CVPixelBuffer` so async work can keep the pixels without holding ARKit's
/// camera-buffer pool. Handles both planar (camera YUV) and non-planar formats.
enum PixelBufferCopy {
    /// A new buffer with the same pixels as `source`, or nil if allocation or the copy fails.
    static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var destination: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &destination
        ) == kCVReturnSuccess, let destination else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        let planeCount = CVPixelBufferGetPlaneCount(source)
        if planeCount == 0 {
            guard copyPlane(
                from: CVPixelBufferGetBaseAddress(source),
                sourceBytesPerRow: CVPixelBufferGetBytesPerRow(source),
                to: CVPixelBufferGetBaseAddress(destination),
                destinationBytesPerRow: CVPixelBufferGetBytesPerRow(destination),
                height: height
            ) else { return nil }
        } else {
            for plane in 0 ..< planeCount {
                guard copyPlane(
                    from: CVPixelBufferGetBaseAddressOfPlane(source, plane),
                    sourceBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                    to: CVPixelBufferGetBaseAddressOfPlane(destination, plane),
                    destinationBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(destination, plane),
                    height: CVPixelBufferGetHeightOfPlane(source, plane)
                ) else { return nil }
            }
        }

        if let attachments = CVBufferCopyAttachments(source, .shouldPropagate) {
            CVBufferSetAttachments(destination, attachments, .shouldPropagate)
        }
        return destination
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
