import Foundation

// Frame rate and processing latency of the analysis pipeline (task T20).

struct FrameTiming: Equatable, Sendable {
    /// When processing started, in seconds on a monotonic clock.
    let timestamp: TimeInterval
    let processingMilliseconds: Double
}

struct PerformanceMetrics: Equatable, Sendable {
    /// Frames processed per second over the timed span.
    let averageFPS: Double
    let averageLatencyMilliseconds: Double
    /// Nearest-rank 95th percentile.
    let p95LatencyMilliseconds: Double
}

func evaluatePerformance(_ timings: [FrameTiming]) -> PerformanceMetrics? {
    guard let first = timings.map(\.timestamp).min(), let last = timings.map(\.timestamp).max() else { return nil }
    let span = last - first
    let latencies = timings.map(\.processingMilliseconds).sorted()
    let p95Index = Int((0.95 * Double(latencies.count)).rounded(.up)) - 1

    return PerformanceMetrics(
        averageFPS: span > 0 ? Double(timings.count - 1) / span : 0,
        averageLatencyMilliseconds: latencies.reduce(0, +) / Double(latencies.count),
        p95LatencyMilliseconds: latencies[p95Index]
    )
}

/// Records how long each frame took to process, keeping the most recent `capacity` frames
/// so it can run for the life of the app.
struct FrameTimer: Sendable {
    let capacity: Int
    private(set) var timings: [FrameTiming] = []

    init(capacity: Int = 120) {
        self.capacity = max(1, capacity)
    }

    /// Records one frame; `start` and `end` come from a monotonic clock such as
    /// `CACurrentMediaTime()`.
    mutating func record(start: TimeInterval, end: TimeInterval) {
        timings.append(FrameTiming(timestamp: start, processingMilliseconds: (end - start) * 1000))
        if timings.count > capacity {
            timings.removeFirst(timings.count - capacity)
        }
    }

    var metrics: PerformanceMetrics? { evaluatePerformance(timings) }
}
