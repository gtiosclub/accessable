import Foundation
import Synchronization

/// Fan-out helper: one producer, many `AsyncStream` subscribers.
///
/// Each subscriber gets its own buffer. The default `bufferingNewest(1)` means a slow subscriber
/// only ever sees the latest value, which is what we want for camera frames and trip state (drop stale data).
final class Broadcaster<Element: Sendable>: Sendable {
    private struct State {
        var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
        var latest: Element?
        var latestSentAt: Date?
    }

    private let state = Mutex(State())
    private let replaysLatest: Bool
    private let replayWindow: (maxAge: TimeInterval, now: @Sendable () -> Date)?

    /// - Parameter replaysLatest: When true, new subscribers immediately receive the most recent value.
    init(replaysLatest: Bool = false) {
        self.replaysLatest = replaysLatest
        replayWindow = nil
    }

    /// New subscribers immediately receive the most recent value only while it is fresh; after that they wait
    /// for the next one, as without replay.
    /// - Parameters:
    ///   - maxAge: Seconds after it was sent that a value is still replayed.
    ///   - now: The current time, to age the latest value.
    init(replaysWithin maxAge: TimeInterval, now: @escaping @Sendable () -> Date = { .now }) {
        replaysLatest = false
        replayWindow = (maxAge, now)
    }

    func stream(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .bufferingNewest(1)) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: bufferingPolicy)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        // One lock covers the replay and the registration, and `send` records and snapshots under the same one:
        // a value sent meanwhile is either replayed here (sent first) or delivered after the replay (sent after),
        // never lost, and never delivered ahead of the replay.
        state.withLock { state in
            if let replay = replayValue(in: state) {
                continuation.yield(replay)
            }
            state.continuations[id] = continuation
        }
        return stream
    }

    /// The most recently sent value. Only recorded when `replaysLatest` is true.
    var latest: Element? { replaysLatest ? state.withLock { $0.latest } : nil }

    func send(_ value: Element) {
        let targets = state.withLock { state in
            if replaysLatest || replayWindow != nil {
                state.latest = value
                state.latestSentAt = replayWindow?.now()
            }
            return Array(state.continuations.values)
        }
        for continuation in targets { continuation.yield(value) }
    }

    func finish() {
        let targets = state.withLock { state in
            defer { state.continuations.removeAll() }
            return Array(state.continuations.values)
        }
        for continuation in targets { continuation.finish() }
    }

    private func replayValue(in state: State) -> Element? {
        if replaysLatest { return state.latest }
        guard let replayWindow, let value = state.latest, let sentAt = state.latestSentAt else { return nil }
        return replayWindow.now().timeIntervalSince(sentAt) <= replayWindow.maxAge ? value : nil
    }
}
