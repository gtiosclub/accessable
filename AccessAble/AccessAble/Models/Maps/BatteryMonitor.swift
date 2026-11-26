import Foundation
import os
import Synchronization

private let log = Logger(subsystem: "AccessAble", category: "BatteryMonitor")

/// Warns during a trip when the battery runs low: once below 20 percent and once below 10, checking when the trip
/// starts and every `checkInterval` after. Says nothing while plugged in or paused.
///
/// Its methods don't suspend, so `TripManager` can call them without an `await` where another call could run.
final class BatteryMonitor: Sendable {
    static let checkInterval: Duration = .seconds(5 * 60)
    private static let lowLevel: Float = 0.2
    private static let veryLowLevel: Float = 0.1

    private struct State {
        /// The trip being watched; a check from an earlier one does nothing.
        var run: UUID?
        var task: Task<Void, Never>?
        var isPaused = false
        var hasWarnedLow = false
        var hasWarnedVeryLow = false
    }

    private let battery: any BatteryReading
    private let announcements: any AnnouncementSink
    private let clock: any Clock<Duration>
    private let state = Mutex(State())

    init(battery: any BatteryReading, announcements: any AnnouncementSink,
         clock: any Clock<Duration> = ContinuousClock()) {
        self.battery = battery
        self.announcements = announcements
        self.clock = clock
    }

    /// Checks now and every `checkInterval` until `stop()`, warning afresh: replaces any trip being watched.
    func start() {
        let run = UUID()
        let previous = state.withLock { state in
            let previous = state.task
            state = State(run: run, task: Task { await self.watch(run: run) })
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
        task?.cancel()
    }

    /// Paused, the checks are skipped rather than put off.
    func setPaused(_ isPaused: Bool) {
        state.withLock { $0.isPaused = isPaused }
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
        let percent = Int((level * 100).rounded())
        let warning: (text: String, key: String)? = state.withLock { state in
            // stopped or paused while the level was read
            guard state.run == run, !state.isPaused else { return nil }
            if level < Self.veryLowLevel, !state.hasWarnedVeryLow {
                // the 20 percent warning would come too late to be news
                state.hasWarnedLow = true
                state.hasWarnedVeryLow = true
                return ("Battery is very low, \(percent) percent. Turning off the camera view saves power.",
                        "battery-10")
            }
            if level < Self.lowLevel, !state.hasWarnedLow {
                state.hasWarnedLow = true
                return ("Battery is low, \(percent) percent.", "battery-20")
            }
            return nil
        }
        guard let warning else { return }
        await announcements.submit(AnnouncementEvent(category: .system, priority: .high, text: warning.text,
                                                     source: .navigation, dedupKey: warning.key))
    }
}
