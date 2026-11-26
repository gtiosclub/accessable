import Synchronization
@testable import AccessAble

/// A battery the test sets, counting how often it is read.
final class FakeBattery: BatteryReading {
    private struct State {
        var status: BatteryStatus
        var reads = 0
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

    func status() async -> BatteryStatus {
        state.withLock { state in
            state.reads += 1
            return state.status
        }
    }
}
