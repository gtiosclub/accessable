import Foundation
import os

private let log = Logger(subsystem: "AccessAble", category: "SavedTrip")

/// The trip in progress, kept on disk so it can be resumed after the app is closed. Only the route and the
/// destination: `NavigationRoute` encodes no reports, and nothing here names the user.
struct SavedTrip: Codable, Equatable, Sendable {
    var tripID: UUID
    var route: NavigationRoute
    /// `route.source`, which `NavigationRoute` doesn't encode, so a resumed backup route still says it is one.
    var routeSource: RouteSource
    var destination: Destination
    /// Steps of `route` before the next one, the departure counted from the start.
    var passedStepCount: Int
    var startedAt: Date
    var savedAt: Date
}

/// Keeps one `SavedTrip` as JSON in Application Support.
///
/// Saving and clearing go through a serial queue, so the trip never waits on the disk and the writes land in order;
/// `load` waits for those before it.
final class SavedTripStore: Sendable {
    /// Seconds; a trip saved this long ago is no longer worth resuming.
    static let maximumAge: TimeInterval = 2 * 60 * 60

    let url: URL
    private let now: @Sendable () -> Date
    private let logError: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "AccessAble.SavedTripStore")

    init(
        directory: URL = .applicationSupportDirectory,
        now: @escaping @Sendable () -> Date = { .now },
        logError: @escaping @Sendable (String) -> Void = { log.error("\($0, privacy: .public)") }
    ) {
        url = directory.appending(path: "SavedTrip.json")
        self.now = now
        self.logError = logError
    }

    func save(_ trip: SavedTrip) {
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                // readable in the background after the first unlock, for a trip walked with the screen locked
                try JSONEncoder().encode(trip).write(
                    to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
                // where the user walked stays on the phone; set on each save, since the atomic write replaces the file
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var written = url
                try written.setResourceValues(values)
            } catch {
                logError("Couldn't save the trip: \(error.localizedDescription)")
            }
        }
    }

    func clear() {
        queue.async { [self] in remove() }
    }

    /// The saved trip, or nil when there is none. One saved `maximumAge` or more ago, or a file that can't be read,
    /// is deleted and gives nil.
    func load() -> SavedTrip? {
        queue.sync {
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
            let trip: SavedTrip
            do {
                trip = try JSONDecoder().decode(SavedTrip.self, from: Data(contentsOf: url))
            } catch {
                logError("Couldn't read the saved trip: \(error.localizedDescription)")
                remove()
                return nil
            }
            guard now().timeIntervalSince(trip.savedAt) < Self.maximumAge else {
                remove()
                return nil
            }
            return trip
        }
    }

    private func remove() {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            logError("Couldn't delete the saved trip: \(error.localizedDescription)")
        }
    }
}
