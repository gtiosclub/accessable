import Foundation
import Observation

/// The caller's Call Help screen: who's online now, starred volunteers, and past calls.
@MainActor
@Observable
final class CallHelpViewModel {
    struct PastCallRow: Identifiable, Equatable {
        let call: PastCall
        let volunteer: Volunteer?
        var id: String { call.id }
        var name: String { volunteer?.name ?? "Volunteer" }
    }

    var search = ""
    private(set) var volunteers: [Volunteer] = []
    private(set) var saved: [SavedPerson] = []
    private(set) var history: [PastCall] = []
    private(set) var hasLoadedVolunteers = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let now: () -> Date

    init(services: AppServices, now: @escaping () -> Date = Date.init) {
        self.services = services
        self.now = now
    }

    // MARK: Live

    private var savedIDs: Set<String> { Set(saved.map(\.id)) }
    private var online: [Volunteer] { volunteers.filter { $0.isReachable(at: now()) } }

    /// Online volunteers the caller starred.
    var liveSaved: [Volunteer] { online.filter { savedIDs.contains($0.id) } }
    /// Everyone else online.
    var liveOthers: [Volunteer] { online.filter { !savedIDs.contains($0.id) } }

    // MARK: History

    var mutuallySaved: [Volunteer] { volunteers(for: saved.filter(\.isMutual)).filter(matchesSearch) }
    var savedOnly: [Volunteer] { volunteers(for: saved.filter { !$0.isMutual }).filter(matchesSearch) }
    var pastCalls: [PastCallRow] {
        let byID = Dictionary(volunteers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return history.map { PastCallRow(call: $0, volunteer: byID[$0.otherID]) }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    func isSaved(_ volunteer: Volunteer) -> Bool { savedIDs.contains(volunteer.id) }
    func isOnline(_ volunteer: Volunteer) -> Bool { volunteer.isReachable(at: now()) }

    /// A starred person as a volunteer to call or message, using the directory when they're in it.
    private func volunteers(for people: [SavedPerson]) -> [Volunteer] {
        let byID = Dictionary(volunteers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return people.map {
            byID[$0.id] ?? Volunteer(id: $0.id, name: $0.name, availableUntil: "", isOnline: false,
                                     lastSeen: .distantPast)
        }
    }

    private func matchesSearch(_ volunteer: Volunteer) -> Bool {
        search.isEmpty || volunteer.name.localizedCaseInsensitiveContains(search)
    }

    // MARK: Loading

    func start() async {
        async let directory: Void = listenToDirectory()
        async let stars: Void = listenToSaves()
        async let calls: Void = loadHistory()
        _ = await (directory, stars, calls)
    }

    func loadHistory() async {
        do { history = try await services.callHistory.pastCalls(as: .caller) }
        catch { errorMessage = error.localizedDescription }
    }

    private func listenToDirectory() async {
        for await list in services.volunteers.allVolunteers() {
            volunteers = list
            hasLoadedVolunteers = true
        }
    }

    private func listenToSaves() async {
        do {
            for try await people in services.saves.savedPeople() { saved = people }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() { errorMessage = nil }
}

/// The star in a chat header, for either side.
@MainActor
@Observable
final class SaveStarModel {
    private(set) var isSaved = false
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let service: any SavesService
    @ObservationIgnored private let personID: String

    init(service: any SavesService, personID: String) {
        self.service = service
        self.personID = personID
    }

    func start() async {
        do {
            for try await people in service.savedPeople() {
                isSaved = people.contains { $0.id == personID }
            }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggle() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let next = !isSaved
        do {
            try await service.setSaved(next, personID: personID)
            isSaved = next
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The caller's Profile tab: name and the optional details.
@MainActor
@Observable
final class CallerProfileViewModel {
    var displayName = ""
    var location = ""
    var condition = ""
    private(set) var isLoaded = false
    private(set) var isSaving = false
    private(set) var message: String?

    @ObservationIgnored private let auth: any AuthService
    @ObservationIgnored private let profiles: any UserProfileStore
    @ObservationIgnored private var profile: UserProfile?

    init(auth: any AuthService, profiles: any UserProfileStore) {
        self.auth = auth
        self.profiles = profiles
    }

    var userID: String? { isLoaded ? profile?.userID : nil }

    var canSave: Bool {
        guard let profile, !isSaving else { return false }
        let details = ProfileDetails(location: location, condition: condition)
        return details.isValid && UserProfileValidation.isValid(displayName: displayName, languages: profile.languages)
    }

    func load() async {
        guard let id = await auth.currentUser()?.id else {
            message = "Sign in to see your profile."
            return
        }
        do {
            guard let loaded = try await profiles.load(userID: id) else { return }
            profile = loaded
            displayName = loaded.displayName
            location = loaded.details.location
            condition = loaded.details.condition
            isLoaded = true
        } catch {
            message = "Couldn't load your profile. Check your connection and try again."
        }
    }

    func save() async {
        guard canSave, let profile else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name != profile.displayName {
                _ = try await profiles.save(userID: profile.userID, role: profile.role,
                                            displayName: name, languages: profile.languages)
            }
            var details = profile.details
            details.location = location
            details.condition = condition
            try await profiles.saveDetails(userID: profile.userID, details: details)
            self.profile?.displayName = name
            self.profile?.details = details
            message = "Profile saved."
        } catch {
            message = "Couldn't save your profile. Try again."
        }
    }
}

/// The volunteer's Live and History tabs: callers who starred them back, chats, and past calls.
@MainActor
@Observable
final class VolunteerCallHelpViewModel {
    struct Caller: Identifiable, Equatable {
        let id: String
        let name: String
    }

    var search = ""
    private(set) var saved: [SavedPerson] = []
    private(set) var history: [PastCall] = []
    private(set) var errorMessage: String?
    let inbox: ChatInboxViewModel

    @ObservationIgnored private let services: AppServices

    init(services: AppServices) {
        self.services = services
        inbox = ChatInboxViewModel(service: services.chat)
    }

    var mutuallySaved: [Caller] {
        saved.filter(\.isMutual).map { Caller(id: $0.id, name: $0.name) }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var pastCalls: [PastCall] {
        history.filter { search.isEmpty || ($0.otherName ?? "").localizedCaseInsensitiveContains(search) }
    }

    func isMutual(callerID: String) -> Bool {
        saved.contains { $0.id == callerID && $0.isMutual }
    }

    /// A volunteer may write first only to a caller who starred them back; otherwise they reply
    /// to a chat the caller started.
    func canMessage(callerID: String) -> Bool {
        saved.contains { $0.id == callerID && $0.isMutual }
            || inbox.threads.contains { ChatID.parties(of: $0.id)?.caller == callerID }
    }

    func start() async {
        async let stars: Void = listenToSaves()
        async let calls: Void = loadHistory()
        async let chats: Void = inbox.start()
        _ = await (stars, calls, chats)
    }

    func loadHistory() async {
        do { history = try await services.callHistory.pastCalls(as: .volunteer) }
        catch { errorMessage = error.localizedDescription }
    }

    private func listenToSaves() async {
        do {
            for try await people in services.saves.savedPeople() { saved = people }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() { errorMessage = nil }
}
