import Foundation
import Synchronization
import Testing
@testable import AccessAble

struct RoutePreferencesMappingTests {
    @Test func everythingOffIsTheDefaultRouteOptions() {
        #expect(RoutePreferences().routeOptions == RouteOptions())
    }

    @Test func walkingSpeedsAreMetresPerSecond() {
        #expect(RoutePreferences(walkingSpeed: .slow).routeOptions.walkingSpeed == 0.9)
        #expect(RoutePreferences(walkingSpeed: .normal).routeOptions.walkingSpeed == 1.2)
        #expect(RoutePreferences(walkingSpeed: .fast).routeOptions.walkingSpeed == 1.5)
    }

    @Test func eachChoiceSetsOnlyItsCosting() {
        func options(_ change: (inout RouteOptions) -> Void) -> RouteOptions {
            var options = RouteOptions()
            change(&options)
            return options
        }
        #expect(RoutePreferences(avoidStairs: true).routeOptions == options { $0.stepPenalty = 3600 })
        #expect(RoutePreferences(avoidElevators: true).routeOptions == options { $0.elevatorPenalty = 3600 })
        #expect(RoutePreferences(avoidSteepHills: true).routeOptions == options { $0.useHills = 0 })
        #expect(RoutePreferences(preferWellLit: true).routeOptions == options { $0.useLit = 1 })
        #expect(RoutePreferences(preferFootpaths: true).routeOptions == options {
            $0.walkwayFactor = 0.8
            $0.sidewalkFactor = 0.8
        })
        #expect(RoutePreferences(avoidAlleysAndDriveways: true).routeOptions == options {
            $0.alleyFactor = 5
            $0.drivewayFactor = 10
        })
        #expect(RoutePreferences(avoidServiceRoads: true).routeOptions == options {
            $0.servicePenalty = 60
            $0.serviceFactor = 3
        })
        #expect(RoutePreferences(avoidUnpavedPaths: true).routeOptions == options {
            $0.useTracks = 0
            $0.maxHikingDifficulty = 0
        })
    }

    @Test func missingKeysDecodeAsDefaults() throws {
        let empty = try JSONDecoder().decode(RoutePreferences.self, from: Data("{}".utf8))
        #expect(empty == RoutePreferences())
        let partial = try JSONDecoder().decode(RoutePreferences.self,
                                               from: Data(#"{"avoidStairs":true,"walkingSpeed":"slow"}"#.utf8))
        #expect(partial == RoutePreferences(avoidStairs: true, walkingSpeed: .slow))
    }
}

/// The account's copy, which can be told to fail.
private actor FakeRoutePreferencesSync: RoutePreferencesSyncing {
    private(set) var remote: [String: RoutePreferences] = [:]
    private(set) var saveCount = 0
    var failsSaves = false

    init(remote: [String: RoutePreferences] = [:]) { self.remote = remote }

    func setFailsSaves(_ fails: Bool) { failsSaves = fails }

    func load(userID: String) async throws -> RoutePreferences? { remote[userID] }

    func save(_ preferences: RoutePreferences, userID: String) async throws {
        saveCount += 1
        if failsSaves { throw URLError(.notConnectedToInternet) }
        remote[userID] = preferences
    }
}

/// A fresh defaults suite and the errors the store logged.
private final class Harness {
    let suite = "RoutePreferencesTests-\(UUID())"
    let defaults: UserDefaults
    private let log = ErrorLog()

    final class ErrorLog: Sendable {
        let messages = Mutex<[String]>([])
    }

    init() { defaults = UserDefaults(suiteName: suite)! }

    deinit { defaults.removePersistentDomain(forName: suite) }

    var errors: [String] { log.messages.withLock { $0 } }

    func store(sync: (any RoutePreferencesSyncing)? = nil) -> RoutePreferencesStore {
        RoutePreferencesStore(defaults: defaults, sync: sync, logError: { [log] message in
            log.messages.withLock { $0.append(message) }
        })
    }
}

@MainActor
struct RoutePreferencesStoreTests {
    private let user = PlaceholderAuthService.sampleUser

    @Test func preferencesSurviveANewStoreOnTheSameDefaults() {
        let harness = Harness()
        harness.store().update(RoutePreferences(avoidStairs: true, walkingSpeed: .fast))
        #expect(harness.store().current == RoutePreferences(avoidStairs: true, walkingSpeed: .fast))
    }

    @Test func corruptDataLoadsDefaultsAndIsLogged() {
        let harness = Harness()
        harness.defaults.set(Data("not JSON".utf8), forKey: "routePreferences.v1")
        #expect(harness.store().current == RoutePreferences())
        #expect(harness.errors.count == 1)
    }

    @Test func viewModelWritesThroughTheStore() async {
        let harness = Harness()
        let store = harness.store()
        var changes = store.changes().makeAsyncIterator()
        #expect(await changes.next() == RoutePreferences())
        let viewModel = RoutePreferencesViewModel(store: store)
        viewModel.preferences.avoidSteepHills = true
        #expect(store.current.avoidSteepHills)
        #expect(await changes.next() == RoutePreferences(avoidSteepHills: true))
        #expect(harness.store().current.avoidSteepHills)
    }

    @Test func signingInReplacesThePhonesPreferencesWithTheAccounts() async throws {
        let harness = Harness()
        let remote = RoutePreferences(avoidElevators: true, walkingSpeed: .slow)
        let sync = FakeRoutePreferencesSync(remote: [user.id: remote])
        let store = harness.store(sync: sync)
        store.update(RoutePreferences(avoidStairs: true))
        harness.defaults.removeObject(forKey: "routePreferences.needsUpload")
        let session = try await readySession(store: store)
        defer { session.task.cancel() }
        try await waitFor { store.current == remote }
        #expect(harness.store().current == remote)
        #expect(await sync.saveCount == 0)
    }

    @Test func signingInToAnAccountWithoutPreferencesUploadsThePhones() async throws {
        let harness = Harness()
        let sync = FakeRoutePreferencesSync()
        let store = harness.store(sync: sync)
        store.update(RoutePreferences(preferWellLit: true))
        let session = try await readySession(store: store)
        defer { session.task.cancel() }
        try await waitFor { await sync.remote[user.id] == RoutePreferences(preferWellLit: true) }
        #expect(store.current == RoutePreferences(preferWellLit: true))
    }

    @Test func aChangeWhileSignedInIsSaved() async throws {
        let sync = FakeRoutePreferencesSync(remote: [user.id: RoutePreferences()])
        let store = Harness().store(sync: sync)
        await store.signedIn(userID: user.id)
        store.update(RoutePreferences(avoidUnpavedPaths: true))
        try await waitFor { await sync.remote[user.id] == RoutePreferences(avoidUnpavedPaths: true) }
    }

    @Test func aFailedSaveKeepsTheChangeAndRetriesWithTheNextChangeAndSignIn() async throws {
        let harness = Harness()
        let sync = FakeRoutePreferencesSync(remote: [user.id: RoutePreferences()])
        let store = harness.store(sync: sync)
        await store.signedIn(userID: user.id)
        await sync.setFailsSaves(true)
        store.update(RoutePreferences(avoidStairs: true))
        try await waitFor { await sync.saveCount == 1 }
        try await waitFor { !harness.errors.isEmpty }
        #expect(store.current == RoutePreferences(avoidStairs: true))
        #expect(await sync.remote[user.id] == RoutePreferences())

        // relaunched: the account's older copy doesn't replace the change that never reached it
        await sync.setFailsSaves(false)
        let relaunched = harness.store(sync: sync)
        await relaunched.signedIn(userID: user.id)
        try await waitFor { await sync.remote[user.id] == RoutePreferences(avoidStairs: true) }
        #expect(relaunched.current == RoutePreferences(avoidStairs: true))

        await sync.setFailsSaves(true)
        relaunched.update(RoutePreferences(avoidStairs: true, avoidElevators: true))
        try await waitFor { await sync.saveCount == 3 }
        await sync.setFailsSaves(false)
        relaunched.update(RoutePreferences(avoidStairs: true, avoidElevators: true, walkingSpeed: .fast))
        try await waitFor {
            await sync.remote[user.id] == RoutePreferences(avoidStairs: true, avoidElevators: true, walkingSpeed: .fast)
        }
    }

    @Test func signingOutForgetsThePreferences() async throws {
        let harness = Harness()
        let sync = FakeRoutePreferencesSync(remote: [user.id: RoutePreferences(avoidStairs: true)])
        let store = harness.store(sync: sync)
        let session = try await readySession(store: store)
        defer { session.task.cancel() }
        try await waitFor { store.current.avoidStairs }
        try await session.model.signOut()
        #expect(store.current == RoutePreferences())
        #expect(harness.store().current == RoutePreferences())
        #expect(await sync.remote[user.id] == RoutePreferences(avoidStairs: true))
    }

    @Test func withoutAccountsThePreferencesStayOnThePhone() async {
        let harness = Harness()
        let store = harness.store()
        store.update(RoutePreferences(avoidServiceRoads: true))
        await store.signedIn(userID: user.id)
        #expect(store.current == RoutePreferences(avoidServiceRoads: true))
        #expect(harness.store().current == RoutePreferences(avoidServiceRoads: true))
        #expect(harness.errors.isEmpty)
    }

    /// A session signed in to `user`, whose profile exists, so it reaches `.ready`.
    private func readySession(store: RoutePreferencesStore) async throws -> (model: AccountSessionViewModel, task: Task<Void, Never>) {
        let profiles = PlaceholderUserProfileStore(profiles: [
            UserProfile(userID: user.id, role: .caller, displayName: "Alice", languages: ["English"], createdAt: .now)
        ])
        let session = AccountSessionViewModel(auth: PlaceholderAuthService(), profiles: profiles, routePreferences: store)
        let task = Task { await session.listen() }
        try await waitFor { if case .ready = session.state { return true }; return false }
        return (session, task)
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw WaitError.timedOut
    }
    private enum WaitError: Error { case timedOut }
}
