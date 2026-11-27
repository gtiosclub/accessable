import Synchronization
@testable import AccessAble

/// A battery the test sets, counting how often it is read and stopped.
final class FakeBattery: BatteryReading {
    private struct State {
        var status: BatteryStatus
        var reads = 0
        var stops = 0
    }

    private let state: Mutex<State>

    init(level: Float?, isChargingOrFull: Bool = false) {
        state = Mutex(State(status: BatteryStatus(level: level, isChargingOrFull: isChargingOrFull)))
    }

    func set(level: Float?, isChargingOrFull: Bool = false) {
        state.withLock { $0.status = BatteryStatus(level: level, isChargingOrFull: isChargingOrFull) }
    }

    var reads: Int {
        state.withLock { $0.reads }
    }

    var stops: Int {
        state.withLock { $0.stops }
    }

    func status() async -> BatteryStatus {
        state.withLock { state in
            state.reads += 1
            return state.status
        }
    }

    func stopReading() async {
        state.withLock { $0.stops += 1 }
    }
}

/// A battery whose `blockedRead`th read waits until `release()`, so a test can act while that reading is in flight.
final class BlockingBattery: BatteryReading {
    private struct State {
        var reads = 0
        var waiting: CheckedContinuation<Void, Never>?
        var isReleased = false
    }

    private let level: Float
    private let blockedRead: Int
    private let state = Mutex(State())

    init(level: Float, blockingRead blockedRead: Int) {
        self.level = level
        self.blockedRead = blockedRead
    }

    var isBlocked: Bool {
        state.withLock { $0.waiting != nil }
    }

    func release() {
        let waiting = state.withLock { state in
            state.isReleased = true
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume()
    }

    func status() async -> BatteryStatus {
        let read = state.withLock { state in
            state.reads += 1
            return state.reads
        }
        if read == blockedRead {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let isReleased = state.withLock { state in
                    if !state.isReleased { state.waiting = continuation }
                    return state.isReleased
                }
                if isReleased { continuation.resume() }
            }
        }
        return BatteryStatus(level: level, isChargingOrFull: false)
    }

    func stopReading() async {}
}
