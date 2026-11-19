import Foundation
import Observation

@MainActor
@Observable
final class AccountSessionViewModel {
    enum State: Equatable {
        case loading
        case signedOut
        case needsProfile(AuthUser)
        case ready(UserProfile)
        case failed(String)
    }

    private(set) var state: State = .loading
    private let auth: any AuthService
    private let profiles: any UserProfileStore
    private var activeUser: AuthUser?
    private var loadTask: Task<Void, Never>?
    private var generation = UUID()

    init(auth: any AuthService, profiles: any UserProfileStore) {
        self.auth = auth
        self.profiles = profiles
    }

    func listen() async {
        defer { loadTask?.cancel() }
        for await user in auth.userChanges() {
            guard !Task.isCancelled else { return }
            loadTask?.cancel()
            activeUser = user
            generation = UUID()
            guard let user else { state = .signedOut; continue }
            state = .loading
            let expected = generation
            loadTask = Task { await load(user: user, generation: expected) }
        }
    }

    func retry() async {
        guard let user = activeUser else { state = .signedOut; return }
        loadTask?.cancel()
        generation = UUID()
        state = .loading
        await load(user: user, generation: generation)
    }

    private func load(user: AuthUser, generation expected: UUID) async {
        do {
            let profile = try await profiles.load(userID: user.id)
            guard !Task.isCancelled, generation == expected, activeUser == user else { return }
            state = profile.map(State.ready) ?? .needsProfile(user)
        } catch {
            guard !Task.isCancelled, generation == expected, activeUser == user else { return }
            if let profileError = error as? UserProfileError {
                state = .failed(profileError.localizedDescription)
            } else {
                state = .failed("We couldn't load your account. Check your connection and try again.")
            }
        }
    }

    func saveProfile(role: UserRole, displayName: String, languages: [String]) async throws {
        guard let user = activeUser, await auth.currentUser() == user else {
            throw AuthError.invalidCredentials
        }
        let expected = generation
        let profile = try await profiles.save(userID: user.id, role: role,
                                              displayName: displayName, languages: languages)
        guard generation == expected, activeUser == user,
              await auth.currentUser() == user else { throw CancellationError() }
        state = .ready(profile)
    }

    func signOut() async throws {
        try await auth.signOut()
        loadTask?.cancel()
        generation = UUID()
        activeUser = nil
        state = .signedOut
    }
}
