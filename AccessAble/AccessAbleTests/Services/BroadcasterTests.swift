import Foundation
import Synchronization
import Testing
@testable import AccessAble

struct BroadcasterReplayWindowTests {
    private final class Time: Sendable {
        private let current = Mutex(Date(timeIntervalSince1970: 0))
        var now: Date { current.withLock { $0 } }
        func advance(by seconds: TimeInterval) { current.withLock { $0 += seconds } }
    }

    private let time = Time()

    private func broadcaster() -> Broadcaster<Int> {
        Broadcaster(replaysWithin: 5, now: { [time] in time.now })
    }

    @Test func aNewSubscriberGetsAFreshLastValueAtOnce() async {
        let broadcaster = broadcaster()
        broadcaster.send(1)
        // exactly the window: still fresh, the boundary is inclusive
        time.advance(by: 5)
        var values = broadcaster.stream().makeAsyncIterator()
        #expect(await values.next() == 1)
    }

    @Test func aValueOlderThanTheWindowIsNotReplayed() async {
        let broadcaster = broadcaster()
        broadcaster.send(1)
        time.advance(by: 5.1)
        let stream = broadcaster.stream(bufferingPolicy: .unbounded)
        broadcaster.send(2)
        broadcaster.finish()
        var received: [Int] = []
        for await value in stream { received.append(value) }
        #expect(received == [2])
    }

    @Test func laterValuesFollowTheReplayedOneInOrder() async {
        let broadcaster = broadcaster()
        broadcaster.send(1)
        let stream = broadcaster.stream(bufferingPolicy: .unbounded)
        broadcaster.send(2)
        broadcaster.send(3)
        broadcaster.finish()
        var received: [Int] = []
        for await value in stream { received.append(value) }
        #expect(received == [1, 2, 3])
    }

    @Test func eachNewSubscriberGetsTheFreshValue() async {
        let broadcaster = broadcaster()
        broadcaster.send(1)
        var first = broadcaster.stream().makeAsyncIterator()
        var second = broadcaster.stream().makeAsyncIterator()
        #expect(await first.next() == 1)
        #expect(await second.next() == 1)
    }
}
