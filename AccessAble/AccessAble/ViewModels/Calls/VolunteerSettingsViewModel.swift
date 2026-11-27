import Foundation
import Observation

@MainActor
@Observable
final class VolunteerSettingsViewModel {
    var displayName: String
    var languageText: String
    /// PROFILE-1: shown on the volunteer's Profile tab.
    var location: String
    private(set) var availability: VolunteerAvailability?
    private(set) var preferences = VolunteerPreferences()
    private(set) var isOnline = false
    private(set) var isInvited = false
    private(set) var isLoaded = false
    private(set) var isBusy = false
    private(set) var message: String?
    @ObservationIgnored let userID: String
    @ObservationIgnored private let store: any VolunteerSettingsStore
    @ObservationIgnored private let profiles: any UserProfileStore
    @ObservationIgnored private let presence: any PresenceService
    @ObservationIgnored private let screen: any ScreenAwakeControlling
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var foregroundRefreshPending = false
    @ObservationIgnored private var details: ProfileDetails
    @ObservationIgnored private let now: () -> Date

    init(profile: UserProfile, store: any VolunteerSettingsStore, profiles: any UserProfileStore,
         presence: any PresenceService, screen: any ScreenAwakeControlling, now: @escaping () -> Date = Date.init) {
        userID = profile.userID; displayName = profile.displayName
        languageText = profile.languages.joined(separator: ", ")
        details = profile.details; location = profile.details.location; availability = profile.details.availability
        self.store = store; self.profiles = profiles; self.presence = presence; self.screen = screen
        self.now = now
    }

    /// Online now by the schedule, or by the Online toggle's saved choice when there's no schedule.
    private var wantsOnline: Bool {
        availability?.isScheduledOnline(at: now()) ?? preferences.onlineByDefault
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
            if let profile {
                displayName = profile.displayName; languageText = profile.languages.joined(separator: ", ")
                details = profile.details; location = profile.details.location; availability = profile.details.availability
            }
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
        do { try await presence.setOnline(wantsOnline && isInvited) }
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

    /// Picks a schedule, saves it, and goes Online or Offline to match it now.
    func setAvailability(_ choice: VolunteerAvailability) async {
        guard isLoaded, !isBusy, choice != availability else { return }
        isBusy = true
        defer { finishOperation() }
        message = nil
        do {
            var next = details; next.availability = choice
            try await profiles.saveDetails(userID: userID, details: next)
            details = next; availability = choice
            // "Always" also comes back Online after a relaunch; "only when I turn it on" keeps the toggle's choice.
            if choice == .always, !preferences.onlineByDefault {
                var prefs = preferences; prefs.onlineByDefault = true
                try await store.save(prefs); preferences = prefs
            }
            if let scheduled = choice.isScheduledOnline(at: now()) {
                try await presence.setOnline(scheduled && isInvited && foreground)
            }
            message = "Availability saved."
        } catch { message = "Couldn't save your availability. Try again." }
    }

    /// While on screen, follows a weekday schedule as its hours start and end. Only a change of
    /// hours acts, so turning Online off by hand in the middle of them sticks.
    func followSchedule(every interval: Duration = .seconds(60)) async {
        var last = availability?.isScheduledOnline(at: now())
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            let scheduled = availability?.isScheduledOnline(at: now())
            defer { last = scheduled }
            if availability == .weekdays, scheduled != last { await applyForegroundPreference() }
        }
    }

    var canSaveDetails: Bool {
        var next = details; next.location = location
        return next.isValid
    }

    func saveProfile() async {
        guard isLoaded, canSaveProfile, canSaveDetails, !isBusy else { return }
        isBusy = true
        defer { finishOperation() }
        do {
            let profile = try await profiles.save(userID: userID, role: .volunteer,
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines), languages: languages)
            displayName = profile.displayName; languageText = profile.languages.joined(separator: ", ")
            var next = details; next.location = location.trimmingCharacters(in: .whitespacesAndNewlines)
            if next != details {
                try await profiles.saveDetails(userID: userID, details: next)
                details = next; location = next.location
            }
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
