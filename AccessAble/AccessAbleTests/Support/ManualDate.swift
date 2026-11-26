import Foundation
import Synchronization

/// A time of day the test moves by hand, for code that reads the date rather than sleeping on a clock.
final class ManualDate: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_700_000_000))

    var now: Date { date.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        date.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}
