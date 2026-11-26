import Foundation
import Testing
@testable import AccessAble

@MainActor
struct UserProfileTests {
    @Test
    func roleAndCreatedAtPersistAcrossProfileUpdates() async throws {
        let store = PlaceholderUserProfileStore()
        let original = try await store.save(userID: "alice", role: .caller,
                                            displayName: "Alice", languages: ["English"])
        let updated = try await store.save(userID: "alice", role: .volunteer,
                                           displayName: "Alice K", languages: ["English", "Korean"])
        #expect(updated.createdAt == original.createdAt)
        #expect(try await store.load(userID: "alice") == updated)
        #expect(try await store.load(userID: "bob") == nil)
    }

    @Test
    func relaunchLoadsSavedVolunteerRole() async throws {
        let auth = PlaceholderAuthService()
        let store = PlaceholderUserProfileStore()
        let first = AccountSessionViewModel(auth: auth, profiles: store)
        let firstTask = Task { await first.listen() }
        defer { firstTask.cancel() }
        try await waitFor { first.state == .needsProfile(PlaceholderAuthService.sampleUser) }
        try await first.saveProfile(role: .volunteer, displayName: "Alex", languages: ["English"])
        firstTask.cancel()
        // A fresh session starts with no local role and restores it from the profile store.
        let relaunched = AccountSessionViewModel(auth: auth, profiles: store)
        let task = Task { await relaunched.listen() }
        defer { task.cancel() }
        try await waitFor {
            if case .ready(let profile) = relaunched.state { return profile.role == .volunteer }
            return false
        }
        try await relaunched.signOut()
        #expect(relaunched.state == .signedOut)
    }

    @Test
    func signingOutDeletesTheSavedTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "UserProfileTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedTrips = SavedTripStore(directory: directory)
        savedTrips.save(SavedTrip(tripID: UUID(), route: MapsSamples.route, routeSource: .valhalla,
                                  destination: MapsSamples.destination, passedStepCount: 1, startedAt: .now,
                                  savedAt: .now))
        #expect(savedTrips.load() != nil)
        let session = AccountSessionViewModel(auth: PlaceholderAuthService(), profiles: PlaceholderUserProfileStore(),
                                              savedTrips: savedTrips)
        try await session.signOut()

        #expect(savedTrips.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: savedTrips.url.path(percentEncoded: false)))
    }

    @Test
    func signingOutEndsTheTripSoItIsntSavedAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "UserProfileTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedTrips = SavedTripStore(directory: directory)
        let trip = TripManager(location: PlaceholderLocationProvider(), routing: PlaceholderRoutingService(),
                               announcements: PlaceholderAnnouncementEngine(), savedTrips: savedTrips)
        await trip.startTrip(route: MapsSamples.route, destination: MapsSamples.destination)
        #expect(savedTrips.load() != nil)
        let session = AccountSessionViewModel(auth: PlaceholderAuthService(), profiles: PlaceholderUserProfileStore(),
                                              savedTrips: savedTrips, trip: trip)
        try await session.signOut()

        var states = trip.tripStates().makeAsyncIterator()
        #expect(await states.next()?.phase == .planning)
        #expect(savedTrips.load() == nil)
    }

    @Test
    func readFailureDoesNotBecomeNewUserOnboarding() async throws {
        let auth = PlaceholderAuthService()
        let session = AccountSessionViewModel(auth: auth, profiles: UnconfiguredUserProfileStore())
        let task = Task { await session.listen() }
        defer { task.cancel() }
        try await waitFor { if case .failed = session.state { return true }; return false }
    }

    @Test
    func rejectsInvalidProfiles() async {
        let store = PlaceholderUserProfileStore()
        await #expect(throws: UserProfileError.invalidProfile) {
            try await store.save(userID: "alice", role: .caller, displayName: " ", languages: [])
        }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw WaitError.timedOut
    }
    private enum WaitError: Error { case timedOut }
}
