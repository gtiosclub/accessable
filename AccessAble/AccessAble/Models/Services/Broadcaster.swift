import Foundation
import Synchronization

/// Fan-out helper: one producer, many `AsyncStream` subscribers.
///
/// Each subscriber gets its own buffer. The default `bufferingNewest(1)` means a slow subscriber
/// only ever sees the latest value, which is what we want for camera frames and trip state (drop stale data).
final class Broadcaster<Element: Sendable>: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])
    private let latest = Mutex<Element?>(nil)
    private let replaysLatest: Bool

    /// - Parameter replaysLatest: When true, new subscribers immediately receive the most recent value.
    init(replaysLatest: Bool = false) {
        self.replaysLatest = replaysLatest
    }

    func stream(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .bufferingNewest(1)) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: bufferingPolicy)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { _ = $0.removeValue(forKey: id) }
        }
        continuations.withLock { $0[id] = continuation }
        if replaysLatest, let value = latest.withLock({ $0 }) {
            continuation.yield(value)
        }
        return stream
    }

    func send(_ value: Element) {
        if replaysLatest { latest.withLock { $0 = value } }
        let targets = continuations.withLock { Array($0.values) }
        for continuation in targets { continuation.yield(value) }
    }

    func finish() {
        let targets = continuations.withLock { dict in
            defer { dict.removeAll() }
            return Array(dict.values)
        }
        for continuation in targets { continuation.finish() }
    }
}
