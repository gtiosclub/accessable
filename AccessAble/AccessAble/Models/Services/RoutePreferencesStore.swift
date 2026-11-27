import Foundation
import os
import Synchronization

private let log = Logger(subsystem: "AccessAble", category: "RoutePreferences")

/// The user's route preferences, kept on the phone and, while signed in, in their account.
///
/// A change applies at once and uploads in the background. A failed upload leaves the change on the phone and is
/// tried again with the next change, or at sign-in if the account has no copy yet. At sign-in the account's copy
/// replaces the phone's. Without `sync`, where the phone has no accounts, the preferences stay on the phone.
final class RoutePreferencesStore: Sendable {
    private struct State {
        var preferences: RoutePreferences
        var userID: String?
        /// Counts local changes, so a sign-in's download doesn't replace a change made while it loaded.
        var revision = 0
        var upload: Task<Void, Never>?
    }

    private enum Keys {
        static let preferences = "routePreferences.v1"
    }

    private let state: Mutex<State>
    /// UserDefaults is thread-safe, though not marked Sendable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let sync: (any RoutePreferencesSyncing)?
    private let logError: @Sendable (String) -> Void
    private let broadcaster = Broadcaster<RoutePreferences>(replaysLatest: true)

    init(
        defaults: UserDefaults = .standard,
        sync: (any RoutePreferencesSyncing)? = nil,
        logError: @escaping @Sendable (String) -> Void = { log.error("\($0, privacy: .public)") }
    ) {
        self.defaults = defaults
        self.sync = sync
        self.logError = logError
        var preferences = RoutePreferences()
        if let data = defaults.data(forKey: Keys.preferences) {
            do {
                preferences = try JSONDecoder().decode(RoutePreferences.self, from: data)
            } catch {
                logError("Couldn't read route preferences, so using the defaults: \(error.localizedDescription)")
            }
        }
        state = Mutex(State(preferences: preferences))
        broadcaster.send(preferences)
    }

    var current: RoutePreferences { state.withLock { $0.preferences } }

    /// The current preferences, then each change.
    func changes() -> AsyncStream<RoutePreferences> { broadcaster.stream() }

    func update(_ preferences: RoutePreferences) {
        let changed = state.withLock { state in
            guard state.preferences != preferences else { return false }
            state.preferences = preferences
            state.revision += 1
            return true
        }
        guard changed else { return }
        store(preferences)
        uploadInBackground()
    }

    /// Brings in the account's preferences, which replace the phone's, even a change that never reached the
    /// account. The phone's are uploaded instead when the account has none. A failed or unreadable download keeps
    /// the phone's.
    func signedIn(userID: String) async {
        guard let sync else { return }
        let revision = state.withLock { state in
            state.userID = userID
            return state.revision
        }
        let remote: RoutePreferences?
        do {
            remote = try await sync.load(userID: userID)
        } catch {
            logError("Couldn't load route preferences: \(error.localizedDescription)")
            return
        }
        let isUnchanged = state.withLock { state in
            // a change made meanwhile is newer than the download, and is already uploading
            guard state.userID == userID, state.revision == revision else { return false }
            if let remote { state.preferences = remote }
            return true
        }
        guard isUnchanged else { return }
        guard let remote else { uploadInBackground(); return }
        store(remote)
    }

    /// Forgets the preferences, so the next account on the phone starts from the defaults.
    func signedOut() {
        let preferences = RoutePreferences()
        state.withLock { state in
            state.userID = nil
            state.preferences = preferences
            state.revision += 1
        }
        defaults.removeObject(forKey: Keys.preferences)
        broadcaster.send(preferences)
    }

    private func store(_ preferences: RoutePreferences) {
        do {
            defaults.set(try JSONEncoder().encode(preferences), forKey: Keys.preferences)
        } catch {
            logError("Couldn't save route preferences: \(error.localizedDescription)")
        }
        broadcaster.send(preferences)
    }

    /// Uploads one at a time, in order, so an older upload never lands after a newer one.
    private func uploadInBackground() {
        guard let sync else { return }
        state.withLock { state in
            guard let userID = state.userID else { return }
            let previous = state.upload
            state.upload = Task { [self] in
                await previous?.value
                await upload(to: sync, userID: userID)
            }
        }
    }

    private func upload(to sync: any RoutePreferencesSyncing, userID: String) async {
        let preferences = state.withLock { $0.userID == userID ? $0.preferences : nil }
        guard let preferences else { return }
        do {
            try await sync.save(preferences, userID: userID)
        } catch {
            logError("Couldn't upload route preferences: \(error.localizedDescription)")
        }
    }
}
