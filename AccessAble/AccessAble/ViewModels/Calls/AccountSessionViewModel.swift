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
    private let presence: any PresenceService
    /// The trip saved for resuming, and the one running, which would save itself again: the next account on the
    /// phone mustn't be offered either.
    private let savedTrips: SavedTripStore?
    private let trip: any TripStateProviding
    /// Kept on the phone, not in the account, so they go with it.
    private let savedPlaces: SavedPlacesStore?
    private let recentPlaces: RecentPlacesStore?
    private var activeUser: AuthUser?
    private var loadTask: Task<Void, Never>?
    private var generation = UUID()

    init(auth: any AuthService, profiles: any UserProfileStore, presence: any PresenceService = PlaceholderPresenceService(),
         savedTrips: SavedTripStore? = nil, trip: any TripStateProviding = PlaceholderTripProvider(),
         savedPlaces: SavedPlacesStore? = nil, recentPlaces: RecentPlacesStore? = nil) {
        self.auth = auth
        self.profiles = profiles
        self.presence = presence
        self.savedTrips = savedTrips
        self.trip = trip
        self.savedPlaces = savedPlaces
        self.recentPlaces = recentPlaces
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
        try? await presence.setOnline(false)
        try await auth.signOut()
        await trip.endTrip()
        savedTrips?.clear()
        savedPlaces?.clear()
        recentPlaces?.clear()
        loadTask?.cancel()
        generation = UUID()
        activeUser = nil
        state = .signedOut
    }
}
