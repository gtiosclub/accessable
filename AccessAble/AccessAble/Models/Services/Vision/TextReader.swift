import CoreVideo
import Foundation
import ImageIO
import Synchronization
import os

/// Runs OCR (T17) beside the perception pipeline rather than inside it.
/// Owner: Computer Vision (1.3).
///
/// Text recognition is too slow to run on every frame without delaying obstacle warnings,
/// and signs don't change from one frame to the next. So reads happen at most once per
/// `interval`, on their own queue, and each frame picks up whatever has been read so far.
/// The pixels are copied before going async so ARKit's camera-buffer pool is not held.
final class TextReader: Sendable {
    private let detector: TextDetector
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "AccessAble.TextReader", qos: .utility)
    private let log = Logger(subsystem: "AccessAble", category: "TextReader")

    private struct State {
        var isReading = false
        var lastReadStart = -TimeInterval.infinity
        var memory = RecognizedTextMemory()
    }

    private let state = Mutex(State())

    init(detector: TextDetector = TextDetector(), interval: TimeInterval = 1) {
        self.detector = detector
        self.interval = interval
    }

    /// A function placing an upright, normalized text box in the world, built from the
    /// frame the text was read from. Called on the OCR queue.
    typealias Locator = @Sendable (CGRect) -> SIMD3<Float>?

    /// Starts a read of `image` in the background if the previous one has finished and
    /// `interval` has passed since it started. `locate`, when given, fills in each text's
    /// `worldPosition` using the same frame, so the position matches the box even though
    /// the read finishes later.
    func readIfDue(
        _ image: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        at time: TimeInterval,
        locate: Locator? = nil
    ) {
        let isDue = state.withLock { state in
            guard !state.isReading, time - state.lastReadStart >= interval else { return false }
            state.isReading = true
            state.lastReadStart = time
            return true
        }
        guard isDue else { return }

        guard let copy = PixelBufferCopy.copy(image) else {
            state.withLock { $0.isReading = false }
            log.error("text recognition skipped: could not copy camera buffer")
            return
        }
        let request = ReadRequest(image: copy, orientation: orientation, time: time)
        queue.async { [self] in
            var texts: [RecognizedText]
            do {
                texts = try detector.detectText(pixelBuffer: request.image, orientation: request.orientation)
                if let locate {
                    texts = texts.map { text in
                        var located = text
                        located.worldPosition = locate(text.boundingBox)
                        return located
                    }
                }
            } catch {
                log.error("text recognition failed: \(error.localizedDescription, privacy: .public)")
                texts = []
            }
            state.withLock { state in
                state.memory.record(texts, at: request.time)
                state.isReading = false
            }
        }
    }

    /// True while a read is running on the OCR queue.
    var isReading: Bool { state.withLock { $0.isReading } }

    /// Text read recently enough to still be relevant at `time`.
    func currentText(at time: TimeInterval) -> [RecognizedText] {
        state.withLock { $0.memory.current(at: time) }
    }
}

/// Carries a copied image to the OCR queue.
///
/// `@unchecked Sendable` because `CVPixelBuffer` is not `Sendable`. It is safe because the
/// buffer is our copy, only read, and only touched on the OCR queue.
private struct ReadRequest: @unchecked Sendable {
    let image: CVPixelBuffer
    let orientation: CGImagePropertyOrientation
    let time: TimeInterval
}
