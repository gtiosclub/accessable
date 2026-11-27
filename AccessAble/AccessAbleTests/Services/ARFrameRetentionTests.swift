import CoreVideo
import Foundation
import ImageIO
import Synchronization
import Testing
@testable import AccessAble

/// ARKit hands out camera images from a pool of a few buffers and stalls when they are all
/// held. These tests stand in for it with a pool that allows a single buffer: a second
/// allocation only succeeds once the code under test has let the first one go.
struct ARFrameRetentionTests {
    private static let cameraFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

    /// A pool of one `width`×`height` buffer, like a starved ARKit pool.
    private func makeSinglePool(
        width: Int = 64, height: Int = 48, format: OSType = cameraFormat
    ) throws -> CVPixelBufferPool {
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        try #require(status == kCVReturnSuccess)
        return try #require(pool)
    }

    /// The pool's buffer, or nil while it is still held.
    private func allocate(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, [kCVPixelBufferPoolAllocationThresholdKey: 1] as CFDictionary, &buffer
        )
        return status == kCVReturnSuccess ? buffer : nil
    }

    private func makeBuffer(
        width: Int, height: Int, format: OSType, attributes: [CFString: Any] = [:]
    ) throws -> CVPixelBuffer {
        var all = attributes
        all[kCVPixelBufferIOSurfacePropertiesKey] = [:] as [CFString: Any]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, all as CFDictionary, &buffer)
        try #require(status == kCVReturnSuccess)
        return try #require(buffer)
    }

    /// Each row of each plane is filled with a byte unique to that plane and row.
    private func fillPattern(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in planes(of: buffer) {
            for row in 0 ..< plane.height {
                memset(plane.base.advanced(by: row * plane.bytesPerRow), Int32(Self.patternByte(plane.index, row)), plane.bytesPerRow)
            }
        }
    }

    /// Whether every visible byte matches `fillPattern`.
    private func hasPattern(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return planes(of: buffer).allSatisfy { plane in
            (0 ..< plane.height).allSatisfy { row in
                let bytes = plane.base.advanced(by: row * plane.bytesPerRow).assumingMemoryBound(to: UInt8.self)
                return (0 ..< plane.rowBytes).allSatisfy { bytes[$0] == Self.patternByte(plane.index, row) }
            }
        }
    }

    private static func patternByte(_ plane: Int, _ row: Int) -> UInt8 { UInt8(truncatingIfNeeded: 0x40 * (plane + 1) + row) }

    private struct Plane {
        let index: Int
        let base: UnsafeMutableRawPointer
        let bytesPerRow: Int
        let height: Int
        /// Bytes of real pixels in a row, without padding.
        let rowBytes: Int
    }

    /// Call with the base address locked.
    private func planes(of buffer: CVPixelBuffer) -> [Plane] {
        let count = CVPixelBufferGetPlaneCount(buffer)
        guard count > 0 else {
            return [Plane(
                index: 0, base: CVPixelBufferGetBaseAddress(buffer)!,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), height: CVPixelBufferGetHeight(buffer),
                rowBytes: CVPixelBufferGetWidth(buffer) * 4
            )]
        }
        // Bi-planar 4:2:0: one byte per luma pixel, two per chroma pair.
        return (0 ..< count).map { index in
            Plane(
                index: index, base: CVPixelBufferGetBaseAddressOfPlane(buffer, index)!,
                bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, index),
                height: CVPixelBufferGetHeightOfPlane(buffer, index),
                rowBytes: CVPixelBufferGetWidthOfPlane(buffer, index) * (index == 0 ? 1 : 2)
            )
        }
    }

    // MARK: - Copying

    @Test
    func copiesBiPlanarCameraFormatPlaneByPlane() throws {
        let source = try makeBuffer(width: 64, height: 48, format: Self.cameraFormat)
        fillPattern(source)

        let copy = try PixelBufferCopier().copy(source)

        #expect(copy !== source)
        #expect(CVPixelBufferGetPixelFormatType(copy) == Self.cameraFormat)
        #expect(CVPixelBufferGetWidth(copy) == 64 && CVPixelBufferGetHeight(copy) == 48)
        #expect(hasPattern(copy))
    }

    @Test
    func copiesBiPlanarRowsWhenRowPaddingDiffers() throws {
        let source = try makeBuffer(
            width: 40, height: 30, format: Self.cameraFormat,
            attributes: [kCVPixelBufferBytesPerRowAlignmentKey: 256]
        )
        fillPattern(source)

        let copy = try PixelBufferCopier().copy(source)

        try #require(CVPixelBufferGetBytesPerRowOfPlane(copy, 0) != CVPixelBufferGetBytesPerRowOfPlane(source, 0))
        #expect(hasPattern(copy))
    }

    @Test
    func copiesBGRAIndependentlyOfSource() throws {
        let source = try makeBuffer(width: 8, height: 8, format: kCVPixelFormatType_32BGRA)
        fillPattern(source)

        let copy = try PixelBufferCopier().copy(source)
        CVPixelBufferLockBaseAddress(source, [])
        memset(CVPixelBufferGetBaseAddress(source)!, 0, CVPixelBufferGetBytesPerRow(source))
        CVPixelBufferUnlockBaseAddress(source, [])

        #expect(hasPattern(copy))
    }

    @Test
    func scaledCopyHasTheRequestedSizeAndFormat() throws {
        let source = try makeBuffer(width: 64, height: 48, format: Self.cameraFormat)
        fillPattern(source)

        let copy = try PixelBufferCopier(size: (16, 16)).copy(source)

        #expect(CVPixelBufferGetWidth(copy) == 16 && CVPixelBufferGetHeight(copy) == 16)
        #expect(CVPixelBufferGetPixelFormatType(copy) == Self.cameraFormat)
    }

    @Test
    func copierSkipsOnceItsPoolIsInUse() throws {
        let copier = PixelBufferCopier()
        let source = try makeBuffer(width: 8, height: 8, format: Self.cameraFormat)
        var held = try (0 ..< PixelBufferCopier.allocationThreshold).map { _ in try copier.copy(source) }

        #expect(throws: PixelBufferCopier.CopyError.poolExhausted) { try copier.copy(source) }

        held.removeLast()
        _ = try copier.copy(source)
    }

    // MARK: - Readers

    @Test
    func textReaderReturnsTheCameraBufferWhileOCRIsPending() throws {
        let queue = DispatchQueue(label: "ARFrameRetentionTests.ocr")
        let reader = TextReader(interval: 0, queue: queue)
        let camera = try makeSinglePool()
        // Parks the read so it can't finish (and let go) before the check.
        queue.suspend()
        defer {
            queue.resume()
            queue.sync {}
        }

        do {
            let image = try #require(allocate(from: camera))
            reader.readIfDue(image, orientation: .up, at: 1)
        }

        #expect(allocate(from: camera) != nil)
    }

    @Test
    func surfaceReaderReturnsTheCameraBufferWhileSegmentationIsPending() throws {
        let model = FileManager.default.temporaryDirectory
            .appendingPathComponent("surface-retention-\(UUID().uuidString).mlmodelc")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: model) }
        let queue = DispatchQueue(label: "ARFrameRetentionTests.segmentation")
        let reader = SurfaceReader(compiledModelURL: model, interval: 0, queue: queue)
        let camera = try makeSinglePool()
        queue.suspend()
        defer {
            queue.resume()
            queue.sync {}
        }

        do {
            let image = try #require(allocate(from: camera))
            reader.readIfDue(image, orientation: .up, at: 1)
        }

        #expect(allocate(from: camera) != nil)
    }

    // MARK: - Ask AI stills

    /// An analyzer whose still capture is fed by `deliver`, called as it subscribes and before
    /// it starts waiting, with a real handler registered on `sessionManager` meanwhile.
    @MainActor
    private func makeAnalyzer(
        sessionManager: ARSessionManager,
        deliver: @escaping @Sendable (_ handler: @Sendable (CVPixelBuffer) -> Void) -> Void
    ) -> ARSceneAnalyzer {
        ARSceneAnalyzer(
            sessionManager: sessionManager,
            performance: PerformanceModeMonitor(),
            announcements: PlaceholderAnnouncementEngine(),
            setMeshReconstruction: { _ in false },
            startSession: {},
            addImageHandler: { handler in
                let subscription = sessionManager.addFrameHandler { _ in }
                deliver(handler)
                return subscription
            }
        )
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func stillCaptureCopiesTheCameraBufferAndUnsubscribes() async throws {
        let sessionManager = ARSessionManager()
        let camera = SendablePool(pool: try makeSinglePool())
        let releasedOnDelivery = Mutex(false)
        let analyzer = makeAnalyzer(sessionManager: sessionManager) { [self] handler in
            if let image = allocate(from: camera.pool) { handler(image) }
            let released = allocate(from: camera.pool) != nil
            releasedOnDelivery.withLock { $0 = released }
        }

        let jpeg = try await analyzer.captureStillImage(timeout: .seconds(30))

        #expect(!jpeg.isEmpty)
        #expect(releasedOnDelivery.withLock { $0 })
        #expect(sessionManager.frameHandlerCount == 0)
    }

    @MainActor @Test(.timeLimit(.minutes(1)))
    func nextCameraImageUnsubscribesBeforeReturningACopy() async throws {
        let sessionManager = ARSessionManager()
        let source = try makeBuffer(width: 64, height: 48, format: Self.cameraFormat)
        fillPattern(source)
        let delivered = CapturedImage(pixelBuffer: source)
        let analyzer = makeAnalyzer(sessionManager: sessionManager) { handler in handler(delivered.pixelBuffer) }

        let image = try #require(await analyzer.nextCameraImage(timeout: .seconds(30)))

        #expect(sessionManager.frameHandlerCount == 0)
        #expect(image.pixelBuffer !== source)
        #expect(hasPattern(image.pixelBuffer))
    }
}

/// Lets the still-capture test reach its pool from the frame handler. `@unchecked Sendable`
/// because `CVPixelBufferPool` is not `Sendable`; CoreVideo pools are thread-safe.
private struct SendablePool: @unchecked Sendable {
    let pool: CVPixelBufferPool
}
