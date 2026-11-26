import Foundation
import os
import Synchronization

private let log = Logger(subsystem: "AccessAble", category: "BatteryMonitor")

/// Decides when a trip should warn that the battery is low: below 20 percent, and again below 10, checking when
/// started and every `checkInterval` after. Says nothing while plugged in or paused.
///
/// The caller speaks each warning and reports it with `delivered(_:)`; until then every check warns again, since the
/// announcement engine drops some, as during a call.
///
/// Its methods don't suspend, so `TripManager` can call them without an `await` where another call could run.
final class BatteryMonitor: Sendable {
    static let checkInterval: Duration = .seconds(5 * 60)
    private static let lowLevel: Float = 0.2
    private static let veryLowLevel: Float = 0.1

    enum Level: Sendable {
        case low, veryLow
    }

    struct Warning: Equatable, Sendable {
        let level: Level
        let text: String
    }

    typealias Warn = @Sendable (Warning) async -> Void

    private struct State {
        /// The trip being watched; a check from an earlier one does nothing.
        var run: UUID?
        var task: Task<Void, Never>?
        var warn: Warn?
        var isPaused = false
        var hasDeliveredLow = false
        var hasDeliveredVeryLow = false
    }

    private let battery: any BatteryReading
    private let clock: any Clock<Duration>
    private let state = Mutex(State())

    init(battery: any BatteryReading, clock: any Clock<Duration> = ContinuousClock()) {
        self.battery = battery
        self.clock = clock
    }

    /// Checks now and every `checkInterval` until `stop()`, warning afresh: replaces any trip being watched.
    func start(isPaused: Bool, warn: @escaping Warn) {
        let run = UUID()
        let previous = state.withLock { state in
            let previous = state.task
            state = State(run: run, task: Task { await self.watch(run: run) }, warn: warn, isPaused: isPaused)
            return previous
        }
        previous?.cancel()
    }

    func stop() {
        let task = state.withLock { state in
            let task = state.task
            state = State()
            return task
        }
        guard let task else { return }
        task.cancel()
        Task { await battery.stopReading() }
    }

    /// Paused, the timer keeps running but its checks are skipped rather than put off; resuming checks at once.
    func setPaused(_ isPaused: Bool) {
        let resumed = state.withLock { state -> UUID? in
            defer { state.isPaused = isPaused }
            return state.isPaused && !isPaused ? state.run : nil
        }
        if let resumed { Task { await check(run: resumed) } }
    }

    /// The warning was spoken, so it isn't given again on this trip.
    func delivered(_ level: Level) {
        state.withLock { state in
            switch level {
            case .low:
                state.hasDeliveredLow = true
            case .veryLow:
                // the 20 percent warning would come too late to be news
                state.hasDeliveredLow = true
                state.hasDeliveredVeryLow = true
            }
        }
    }

    private func watch(run: UUID) async {
        while true {
            await check(run: run)
            do { try await clock.sleep(for: Self.checkInterval) } catch { return }
        }
    }

    private func check(run: UUID) async {
        guard state.withLock({ $0.run == run && !$0.isPaused }) else { return }
        let status = await battery.status()
        guard !status.isChargingOrFull else { return }
        guard let level = status.level else {
            log.notice("Battery level unknown; skipping the low-battery check")
            return
        }
        let due: (warning: Warning, warn: Warn)? = state.withLock { state in
            // stopped or paused while the level was read
            guard state.run == run, !state.isPaused, let warn = state.warn else { return nil }
            if level < Self.veryLowLevel, !state.hasDeliveredVeryLow {
                let percent = Self.percent(level, below: Self.veryLowLevel)
                return (Warning(level: .veryLow, text: "Battery is very low, \(percent) percent. "
                                    + "Turning off the camera view saves power."), warn)
            }
            if level < Self.lowLevel, !state.hasDeliveredLow {
                let percent = Self.percent(level, below: Self.lowLevel)
                return (Warning(level: .low, text: "Battery is low, \(percent) percent."), warn)
            }
            return nil
        }
        guard let due else { return }
        await due.warn(due.warning)
    }

    /// Rounded, but under the threshold crossed, so 19.5 percent isn't said as "low, 20 percent".
    private static func percent(_ level: Float, below threshold: Float) -> Int {
        min(Int((level * 100).rounded()), Int((threshold * 100).rounded()) - 1)
    }
}
