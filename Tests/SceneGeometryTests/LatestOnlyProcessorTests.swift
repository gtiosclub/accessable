import Foundation
import Synchronization
import Testing
@testable import SceneGeometry

@Suite("T3 — latest-only processing")
struct LatestOnlyProcessorTests {
    @Test("values submitted while busy collapse to the newest one")
    func dropsStaleValues() {
        let processed = Mutex<[Int]>([])
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)

        let processor = LatestOnlyProcessor<Int>(label: "test") { value in
            if value == 1 {
                firstStarted.signal()
                releaseFirst.wait()
            }
            processed.withLock { $0.append(value) }
            if value == 5 { finished.signal() }
        }

        processor.submit(1)
        firstStarted.wait()
        for value in 2 ... 5 {
            processor.submit(value)
        }
        releaseFirst.signal()

        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(processed.withLock { $0 } == [1, 5])
    }

    @Test("an idle processor handles each value as it arrives")
    func processesWhenIdle() {
        let processed = Mutex<[Int]>([])
        let done = DispatchSemaphore(value: 0)
        let processor = LatestOnlyProcessor<Int>(label: "test") { value in
            processed.withLock { $0.append(value) }
            done.signal()
        }

        for value in 1 ... 3 {
            processor.submit(value)
            #expect(done.wait(timeout: .now() + 2) == .success)
        }
        #expect(processed.withLock { $0 } == [1, 2, 3])
    }

    @Test("cancelPending drops the value waiting behind the current one")
    func cancelsPending() {
        let processed = Mutex<[Int]>([])
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstDone = DispatchSemaphore(value: 0)

        let processor = LatestOnlyProcessor<Int>(label: "test") { value in
            if value == 1 {
                firstStarted.signal()
                releaseFirst.wait()
            }
            processed.withLock { $0.append(value) }
            if value == 1 { firstDone.signal() }
        }

        processor.submit(1)
        firstStarted.wait()
        processor.submit(2)
        processor.cancelPending()
        releaseFirst.signal()

        #expect(firstDone.wait(timeout: .now() + 2) == .success)
        // Give a wrongly retained value time to run before checking it didn't.
        Thread.sleep(forTimeInterval: 0.05)
        #expect(processed.withLock { $0 } == [1])
    }
}
