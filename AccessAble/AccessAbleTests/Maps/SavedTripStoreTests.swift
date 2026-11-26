import Foundation
import Synchronization
import Testing
@testable import AccessAble

/// A temporary directory, a clock the test sets, and the errors the store logged.
private final class StoreHarness: Sendable {
    let directory = FileManager.default.temporaryDirectory.appending(path: "SavedTripStoreTests-\(UUID())")
    let time = ManualDate()
    let errors = ErrorLog()
    let store: SavedTripStore

    final class ErrorLog: Sendable {
        private let messages = Mutex<[String]>([])

        func append(_ message: String) {
            messages.withLock { $0.append(message) }
        }

        var count: Int { messages.withLock { $0.count } }
    }

    init() {
        store = SavedTripStore(directory: directory, now: { [time] in time.now },
                               logError: { [errors] in errors.append($0) })
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var fileExists: Bool { FileManager.default.fileExists(atPath: store.url.path()) }

    func trip() -> SavedTrip {
        let now = time.now
        return SavedTrip(tripID: UUID(), route: MapsSamples.route, destination: MapsSamples.destination,
                         passedStepCount: 1, startedAt: now.addingTimeInterval(-60), savedAt: now)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SavedTripStoreTests {
    @Test
    func aSavedTripLoadsBackTheSame() {
        let harness = StoreHarness()
        let trip = harness.trip()
        harness.store.save(trip)

        #expect(harness.store.load() == trip)
        #expect(harness.store.url.lastPathComponent == "SavedTrip.json")
    }

    @Test
    func theFileHoldsNoReports() throws {
        let harness = StoreHarness()
        var trip = harness.trip()
        var route = trip.route
        route.unavoidedReports = [Report(id: "r1", kind: .blockedPath, coordinate: MapsSamples.origin,
                                         createdAt: .now, expiresAt: .now, reporterID: "someone")]
        trip.route = route
        harness.store.save(trip)
        _ = harness.store.load()

        let text = try String(contentsOf: harness.store.url, encoding: .utf8)
        #expect(!text.contains("someone"))
        #expect(!text.contains("r1"))
    }

    @Test
    func noFileLoadsNothing() {
        let harness = StoreHarness()
        #expect(harness.store.load() == nil)
        #expect(harness.errors.count == 0)
    }

    @Test(arguments: [SavedTripStore.maximumAge, SavedTripStore.maximumAge + 1])
    func aTripTwoHoursOldOrMoreIsDeleted(_ age: TimeInterval) {
        let harness = StoreHarness()
        harness.store.save(harness.trip())
        harness.time.advance(by: age)

        #expect(harness.store.load() == nil)
        #expect(!harness.fileExists)
    }

    @Test
    func aTripJustUnderTwoHoursOldLoads() {
        let harness = StoreHarness()
        let trip = harness.trip()
        harness.store.save(trip)
        harness.time.advance(by: SavedTripStore.maximumAge - 1)

        #expect(harness.store.load() == trip)
    }

    @Test
    func anUnreadableFileIsDeletedAndLogged() throws {
        let harness = StoreHarness()
        try FileManager.default.createDirectory(at: harness.directory, withIntermediateDirectories: true)
        try Data("not a trip".utf8).write(to: harness.store.url)

        #expect(harness.store.load() == nil)
        #expect(!harness.fileExists)
        #expect(harness.errors.count == 1)
    }

    @Test
    func clearDeletesTheTrip() {
        let harness = StoreHarness()
        harness.store.save(harness.trip())
        harness.store.clear()

        #expect(harness.store.load() == nil)
        #expect(!harness.fileExists)
        #expect(harness.errors.count == 0)
    }
}
