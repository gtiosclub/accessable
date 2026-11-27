import Foundation
import OSLog

private let log = Logger(subsystem: "AccessAble", category: "PlaceStorage")

/// Stores a list of saved or recent places in `UserDefaults` as JSON. Stored data that no longer
/// decodes (say, written by a newer build) is kept under `backupKey(for:)`, so the next save
/// doesn't silently wipe the user's places.
enum PlaceListDefaults {
    static func backupKey(for key: String) -> String { "\(key).undecodable" }

    static func load<Place: Decodable>(from defaults: UserDefaults, key: String) -> [Place] {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([Place].self, from: data)
        } catch {
            let backupKey = backupKey(for: key)
            defaults.set(data, forKey: backupKey)
            log.error("Stored \(key, privacy: .public) don't decode, kept under \(backupKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    static func save<Place: Encodable>(_ places: [Place], to defaults: UserDefaults, key: String) {
        do {
            defaults.set(try JSONEncoder().encode(places), forKey: key)
        } catch {
            log.error("Couldn't store \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes the list and any undecodable backup of it, as on sign-out.
    static func remove(from defaults: UserDefaults, key: String) {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: backupKey(for: key))
    }
}
