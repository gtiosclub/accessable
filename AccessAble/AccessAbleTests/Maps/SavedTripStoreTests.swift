import Foundation
import Testing
@testable import AccessAble

struct SavedTripStoreTests {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func store(now: Date = start.addingTimeInterval(60)) -> (store: SavedTripStore, cleanUp: () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SavedTripStoreTests-\(UUID())")
        return (SavedTripStore(fileURL: directory.appending(path: "SavedTrip.json"), now: { now }),
                { try? FileManager.default.removeItem(at: directory) })
    }

    private var trip: SavedTrip {
        SavedTrip(tripID: UUID(), route: MapsSamples.route,
                  destination: Destination(name: "Clough Commons", coordinate: MapsSamples.destination.coordinate),
                  passedSteps: 1, startedAt: Self.start)
    }

    @Test
    func loadsWhatWasSaved() {
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let saved = trip

        store.save(saved)

        #expect(store.load() == saved)
    }

    @Test
    func loadsNothingWhenNothingWasSaved() {
        let (store, cleanUp) = store()
        defer { cleanUp() }

        #expect(store.load() == nil)
    }

    @Test
    func offersATripUnderTwoHoursOld() {
        let (store, cleanUp) = store(now: Self.start.addingTimeInterval(2 * 60 * 60 - 1))
        defer { cleanUp() }
        store.save(trip)

        #expect(store.load() != nil)
    }

    @Test
    func dropsATripOfTwoHoursOrMore() {
        let (store, cleanUp) = store(now: Self.start.addingTimeInterval(2 * 60 * 60))
        defer { cleanUp() }
        store.save(trip)

        #expect(store.load() == nil)
        // deleted rather than only hidden
        #expect(store.load() == nil)
    }

    @Test
    func clearDeletesTheSavedTrip() {
        let (store, cleanUp) = store()
        defer { cleanUp() }
        store.save(trip)

        store.clear()

        #expect(store.load() == nil)
    }

    @Test
    func dropsAFileItCannotRead() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SavedTripStoreTests-corrupt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "SavedTrip.json")
        try Data("not json".utf8).write(to: url)

        #expect(SavedTripStore(fileURL: url).load() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
