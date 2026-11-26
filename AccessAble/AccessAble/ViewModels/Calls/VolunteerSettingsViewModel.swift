import Foundation
import Observation

@MainActor
@Observable
final class VolunteerSettingsViewModel {
    var displayName: String
    var languageText: String
    private(set) var preferences = VolunteerPreferences()
    private(set) var isOnline = false
    private(set) var isInvited = false
    private(set) var isLoaded = false
    private(set) var isBusy = false
    private(set) var message: String?
    @ObservationIgnored private let userID: String
    @ObservationIgnored private let store: any VolunteerSettingsStore
    @ObservationIgnored private let profiles: any UserProfileStore
    @ObservationIgnored private let presence: any PresenceService
    @ObservationIgnored private let screen: any ScreenAwakeControlling
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var foregroundRefreshPending = false

    init(profile: UserProfile, store: any VolunteerSettingsStore, profiles: any UserProfileStore,
         presence: any PresenceService, screen: any ScreenAwakeControlling) {
        userID = profile.userID; displayName = profile.displayName
        languageText = profile.languages.joined(separator: ", ")
        self.store = store; self.profiles = profiles; self.presence = presence; self.screen = screen
    }

    var languages: [String] {
        languageText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    var canSaveProfile: Bool { UserProfileValidation.isValid(displayName: displayName, languages: languages) }

    func load() async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        do {
            let prefs = try await store.preferences()
            let invited = try await store.isInvited()
            let profile = try await profiles.load(userID: userID)
            guard !Task.isCancelled else { isBusy = false; return }
            preferences = prefs; isInvited = invited
            if let profile { displayName = profile.displayName; languageText = profile.languages.joined(separator: ", ") }
            isLoaded = true
        } catch { message = "Couldn't load volunteer settings. Check your connection and retry." }
        isBusy = false
        updateScreen()
        await applyForegroundPreference()
    }

    func observePresence() async {
        defer { screen.setAwake(false) }
        for await online in presence.onlineStates() {
            guard !Task.isCancelled else { return }
            isOnline = online
            updateScreen()
        }
    }

    func setForeground(_ active: Bool) async {
        foreground = active
        updateScreen()
        if active {
            if isBusy { foregroundRefreshPending = true }
            else { await applyForegroundPreference() }
        } else {
            foregroundRefreshPending = false
            // Enqueued after any in-flight Online write by the real presence service.
            try? await presence.setOnline(false)
        }
    }

    private func applyForegroundPreference() async {
        guard foreground, isLoaded, !isBusy else { return }
        isBusy = true
        defer { finishOperation() }
        do { try await presence.setOnline(preferences.onlineByDefault && isInvited) }
        catch { message = (error as? LocalizedError)?.errorDescription ?? "Couldn't go online. Try again." }
    }

    func setOnline(_ online: Bool) async {
        guard isLoaded, !isBusy else { return }
        isBusy = true
        defer { finishOperation() }
        message = nil
        do {
            if online { isInvited = try await store.isInvited(); guard isInvited else { throw CallSafetyError.invitationRequired } }
            var next = preferences; next.onlineByDefault = online
            try await store.save(next)
            preferences = next
            try await presence.setOnline(online && foreground)
        } catch { message = (error as? LocalizedError)?.errorDescription ?? "Couldn't change your availability." }
    }

    func setKeepAwake(_ awake: Bool) async {
        guard isLoaded, !isBusy else { return }
        isBusy = true
        defer { finishOperation() }
        do {
            var next = preferences; next.keepScreenAwake = awake
            try await store.save(next); preferences = next
            message = "Settings saved."
        } catch { message = "Couldn't save the screen setting. Try again." }
    }

    func setOnlineByDefault(_ online: Bool) async {
        guard isLoaded, !isBusy else { return }
        isBusy = true
        defer { finishOperation() }
        do {
            var next = preferences; next.onlineByDefault = online
            try await store.save(next); preferences = next
            try await presence.setOnline(online && isInvited && foreground)
            message = "Start-online preference saved."
        } catch { message = "Couldn't save your start-online preference. Try again." }
    }

    func saveProfile() async {
        guard isLoaded, canSaveProfile, !isBusy else { return }
        isBusy = true
        defer { finishOperation() }
        do {
            let profile = try await profiles.save(userID: userID, role: .volunteer,
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines), languages: languages)
            displayName = profile.displayName; languageText = profile.languages.joined(separator: ", ")
            do { try await presence.refreshProfile(); message = "Profile saved." }
            catch { message = "Profile saved. The directory couldn't update yet; save again to retry." }
        } catch { message = "Couldn't save your profile. Try again." }
    }

    func shutdown() {
        stopLocally()
        let presence = presence
        Task { try? await presence.setOnline(false) }
    }

    /// Before signing out: the Offline write needs the signed-in user, so it must finish first,
    /// or the server keeps showing this volunteer Online for up to 90 seconds.
    func shutdownBeforeSignOut() async {
        stopLocally()
        try? await presence.setOnline(false)
    }

    private func stopLocally() {
        foreground = false
        foregroundRefreshPending = false
        screen.setAwake(false)
    }

    private func finishOperation() {
        isBusy = false
        updateScreen()
        if foregroundRefreshPending && foreground {
            foregroundRefreshPending = false
            Task { await applyForegroundPreference() }
        }
    }
    private func updateScreen() { screen.setAwake(foreground && isLoaded && isOnline && preferences.keepScreenAwake) }
}
