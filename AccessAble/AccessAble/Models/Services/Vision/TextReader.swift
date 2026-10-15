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
/// The image being read keeps one of ARKit's frame buffers alive for the length of a read.
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

    /// Starts a read of `image` in the background if the previous one has finished and
    /// `interval` has passed since it started.
    func readIfDue(_ image: CVPixelBuffer, orientation: CGImagePropertyOrientation, at time: TimeInterval) {
        let isDue = state.withLock { state in
            guard !state.isReading, time - state.lastReadStart >= interval else { return false }
            state.isReading = true
            state.lastReadStart = time
            return true
        }
        guard isDue else { return }

        let request = ReadRequest(image: image, orientation: orientation, time: time)
        queue.async { [self] in
            let texts: [RecognizedText]
            do {
                texts = try detector.detectText(pixelBuffer: request.image, orientation: request.orientation)
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

    /// Text read recently enough to still be relevant at `time`.
    func currentText(at time: TimeInterval) -> [RecognizedText] {
        state.withLock { $0.memory.current(at: time) }
    }
}

/// Carries the image to the OCR queue.
///
/// `@unchecked Sendable` because `CVPixelBuffer` is not `Sendable`. It is safe because the
/// buffer is only read, and ARKit does not reuse it while it is retained here.
private struct ReadRequest: @unchecked Sendable {
    let image: CVPixelBuffer
    let orientation: CGImagePropertyOrientation
    let time: TimeInterval
}
