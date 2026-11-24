import Foundation
import os

private let log = Logger(subsystem: "AccessAble", category: "SavedTrip")

/// A trip in progress, kept on disk so closing or crashing the app mid-walk doesn't lose it.
struct SavedTrip: Codable, Equatable, Sendable {
    var tripID: UUID
    var route: NavigationRoute
    var destination: Destination
    /// The index of the step the user was heading for: the steps before it are behind them.
    var passedSteps: Int
    var startedAt: Date
}

/// The one saved trip, a JSON file in Application Support. Only the running trip writes it, and it is deleted when
/// the trip ends or arrives, so a file that is still there means the app stopped mid-trip.
struct SavedTripStore: Sendable {
    /// Older than this, a trip is no longer one the user is still walking.
    static let maximumAge: TimeInterval = 2 * 60 * 60

    private let fileURL: URL
    private let now: @Sendable () -> Date

    init(
        fileURL: URL = URL.applicationSupportDirectory.appending(path: "SavedTrip.json"),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.fileURL = fileURL
        self.now = now
    }

    func save(_ trip: SavedTrip) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(trip).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Could not save the trip: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The saved trip if it is under two hours old. An older or unreadable one is deleted rather than offered.
    func load() -> SavedTrip? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let trip = try? JSONDecoder().decode(SavedTrip.self, from: data),
              now().timeIntervalSince(trip.startedAt) < Self.maximumAge else {
            clear()
            return nil
        }
        return trip
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
