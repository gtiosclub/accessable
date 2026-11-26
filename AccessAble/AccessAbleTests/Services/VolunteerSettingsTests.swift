import Foundation
import Testing
@testable import AccessAble

@MainActor
struct VolunteerSettingsTests {
    @Test func defaultsGoOnlineAndKeepScreenAwakeOnlyForAnApprovedForegroundVolunteer() async throws {
        let h = SettingsHarness()
        defer { h.stop() }
        await h.start()
        try await waitFor { h.model.isOnline && h.screen.awake }
        #expect(h.model.preferences == VolunteerPreferences(onlineByDefault: true, keepScreenAwake: true))
        await h.model.setForeground(false)
        #expect(!h.screen.awake)
        h.model.shutdown()
        #expect(!h.screen.awake)
    }

    @Test func onlineAndScreenChoicesSurviveANewViewModel() async throws {
        let h = SettingsHarness()
        defer { h.stop() }
        await h.start()
        await h.model.setOnline(false)
        await h.model.setKeepAwake(false)
        try await waitFor { !h.model.isOnline }
        let reloaded = VolunteerSettingsViewModel(profile: h.profile, store: h.store, profiles: h.profiles,
                                                 presence: h.presence, screen: SettingsScreen())
        await reloaded.setForeground(true)
        await reloaded.load()
        #expect(reloaded.preferences == VolunteerPreferences(onlineByDefault: false, keepScreenAwake: false))
        reloaded.shutdown()
    }

    @Test func offlineOrDisabledKeepAwakeRestoresTheScreen() async throws {
        let h = SettingsHarness()
        defer { h.stop() }
        await h.start()
        try await waitFor { h.screen.awake }
        await h.model.setKeepAwake(false)
        #expect(!h.screen.awake)
        await h.model.setKeepAwake(true)
        #expect(h.screen.awake)
        await h.model.setOnline(false)
        try await waitFor { !h.screen.awake }
    }

    @Test func uninvitedAccountDoesNotGoOnlineAndCanChooseNotToStartOnline() async throws {
        let h = SettingsHarness()
        defer { h.stop() }
        await h.store.setInvited(false)
        await h.start()
        #expect(!h.model.isInvited && !h.model.isOnline && !h.screen.awake)
        await h.model.setOnline(true)
        #expect(h.model.message == CallSafetyError.invitationRequired.errorDescription)
        #expect(!h.model.isOnline)
        await h.model.setOnlineByDefault(false)
        #expect(!h.model.preferences.onlineByDefault)
    }

    @Test func profileChangesPersistWithoutChangingAccountCreationTime() async throws {
        let h = SettingsHarness()
        defer { h.stop() }
        await h.start()
        h.model.displayName = "Sam Kim"
        h.model.languageText = "English, Korean"
        await h.model.saveProfile()
        let stored = try await h.profiles.load(userID: h.profile.userID)
        #expect(stored?.displayName == "Sam Kim")
        #expect(stored?.languages == ["English", "Korean"])
        #expect(stored?.createdAt == h.profile.createdAt)
    }

    @Test func failedPreferenceWriteDoesNotPretendTheValueWasSaved() async throws {
        let h = SettingsHarness()
        defer { h.stop() }
        await h.start()
        await h.store.setFailing(true)
        await h.model.setKeepAwake(false)
        #expect(h.model.preferences.keepScreenAwake)
        #expect(h.model.message != nil)
    }

    @Test func initialLoadFailureCannotEnableAvailabilityOrKeepAwake() async {
        let h = SettingsHarness()
        defer { h.stop() }
        await h.store.setFailing(true)
        await h.start()
        #expect(!h.model.isLoaded)
        #expect(!h.model.isOnline && !h.screen.awake)
        #expect(h.model.message != nil)
    }

    @Test func returningToForegroundRestoresOnlineWithoutChangingTheSavedPreference() async throws {
        let h = SettingsHarness()
        defer { h.stop() }
        await h.start()
        try await waitFor { h.model.isOnline }
        await h.model.setForeground(false)
        try await waitFor { !h.model.isOnline && !h.screen.awake }
        #expect(h.model.preferences.onlineByDefault)
        await h.model.setForeground(true)
        try await waitFor { h.model.isOnline && h.screen.awake }
    }

    @Test func leavingDuringASlowPreferenceSaveCannotBringTheVolunteerBackOnline() async throws {
        let h = SettingsHarness()
        defer { h.stop() }
        await h.start()
        await h.model.setOnline(false)
        await h.store.pauseNextSave()
        let saving = Task { await h.model.setOnline(true) }
        await h.store.waitForSave()
        await h.model.setForeground(false)
        h.model.shutdown()
        await h.store.resumeSave()
        await saving.value
        try await waitFor { !h.model.isOnline }
        #expect(!h.screen.awake)
        #expect(h.model.preferences.onlineByDefault)
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CallSafetyError.unavailable
    }
}

@MainActor
private final class SettingsHarness {
    let profile: UserProfile
    let store: SettingsMemoryStore
    let profiles: PlaceholderUserProfileStore
    let presence: PlaceholderPresenceService
    let screen: SettingsScreen
    let model: VolunteerSettingsViewModel
    private var observer: Task<Void, Never>?
    init() {
        let profile = UserProfile(userID: "helper", role: .volunteer, displayName: "Sam", languages: ["English"], createdAt: .now)
        let store = SettingsMemoryStore(), profiles = PlaceholderUserProfileStore(profiles: [profile])
        let presence = PlaceholderPresenceService(), screen = SettingsScreen()
        self.profile = profile; self.store = store; self.profiles = profiles
        self.presence = presence; self.screen = screen
        model = VolunteerSettingsViewModel(profile: profile, store: store, profiles: profiles, presence: presence, screen: screen)
    }
    func start() async {
        observer = Task { await model.observePresence() }
        await model.setForeground(true)
        await model.load()
    }
    func stop() { observer?.cancel(); model.shutdown() }
}

private actor SettingsMemoryStore: VolunteerSettingsStore {
    private var value = VolunteerPreferences()
    private var invited = true
    private var failing = false
    private var shouldPause = false
    private var pausedSave: CheckedContinuation<Void, Never>?
    private var saveWaiter: CheckedContinuation<Void, Never>?
    func pauseNextSave() { shouldPause = true }
    func waitForSave() async {
        if pausedSave != nil { return }
        await withCheckedContinuation { saveWaiter = $0 }
    }
    func resumeSave() { pausedSave?.resume(); pausedSave = nil }

    func setInvited(_ value: Bool) { invited = value }
    func setFailing(_ value: Bool) { failing = value }
    func preferences() async throws -> VolunteerPreferences { if failing { throw CallSafetyError.unavailable }; return value }
    func save(_ preferences: VolunteerPreferences) async throws {
        if shouldPause {
            shouldPause = false
            await withCheckedContinuation { pausedSave = $0; saveWaiter?.resume(); saveWaiter = nil }
        }
        if failing { throw CallSafetyError.unavailable }
        value = preferences
    }
    func isInvited() async throws -> Bool { invited }
}

@MainActor
private final class SettingsScreen: ScreenAwakeControlling {
    var awake = false
    func setAwake(_ awake: Bool) { self.awake = awake }
}
