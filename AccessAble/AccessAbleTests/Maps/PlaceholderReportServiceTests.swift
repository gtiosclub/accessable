import Foundation
import Synchronization
import Testing
@testable import AccessAble

/// Whoever the test signs in.
private final class SwitchableAuth: AuthService, Sendable {
    private let user = Mutex<AuthUser?>(nil)

    func use(_ id: String?) { user.withLock { $0 = id.map { AuthUser(id: $0) } } }
    func userChanges() -> AsyncStream<AuthUser?> { AsyncStream { $0.finish() } }
    func currentUser() async -> AuthUser? { user.withLock { $0 } }
    func signIn(email: String, password: String) async throws -> AuthUser { AuthUser(id: email) }
    func createAccount(email: String, password: String) async throws -> AuthUser { AuthUser(id: email) }
    func signOut() async throws { use(nil) }
}

/// A time the test moves by hand.
private final class TestTime: Sendable {
    private let time: Mutex<Date>

    init(_ time: Date) { self.time = Mutex(time) }
    func advance(by interval: TimeInterval) { time.withLock { $0 += interval } }
    func now() -> Date { time.withLock { $0 } }
}

struct PlaceholderReportServiceTests {
    private let coordinate = GeoCoordinate(
        latitude: 33.7756,
        longitude: -84.3963
    )

    /// One stored report from one captured date, so every read of it is equal.
    private let sample: Report
    /// The sample as its reporter reads it back.
    private var own: Report {
        var own = sample
        own.isOwn = true
        return own
    }

    init() {
        let createdAt = Date.now
        sample = Report(
            id: "r1",
            kind: .construction,
            coordinate: coordinate,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(3600)
        )
    }

    @Test
    func storesAndFindsNearbyReport() async throws {
        let service = PlaceholderReportService()
        try await service.submit(sample)

        let actual = try await service.reports(near: coordinate, radius: 100)
        #expect(actual == [own])
    }

    @Test
    func publishesNewReportsToLiveStream() async throws {
        let service = PlaceholderReportService()
        var iterator = service.reportChanges(
            near: coordinate,
            radius: 100
        ).makeAsyncIterator()

        #expect(await iterator.next() == [])
        try await service.submit(sample)
        #expect(await iterator.next() == [own])
    }

    @Test
    func aReportIsOwnOnlyForTheUserWhoSubmittedIt() async throws {
        let auth = SwitchableAuth()
        let service = PlaceholderReportService(auth: auth)
        auth.use("reporter")
        try await service.submit(sample)

        #expect(try await service.reports(near: coordinate, radius: 100) == [own])
        auth.use("someone else")
        #expect(try await service.reports(near: coordinate, radius: 100) == [sample])
        auth.use(nil)
        #expect(try await service.reports(near: coordinate, radius: 100) == [sample])
    }

    // MARK: Votes

    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// A blocked path reported at `start` by "reporter", ending in an hour, with `voter` signed in a quarter of an hour on.
    private func votingService(voter: String = "voter") async throws -> (PlaceholderReportService, SwitchableAuth, TestTime) {
        let auth = SwitchableAuth()
        let clock = TestTime(Self.start)
        let service = PlaceholderReportService(auth: auth, now: { clock.now() })
        auth.use("reporter")
        try await service.submit(Report(
            id: "r1", kind: .blockedPath, coordinate: coordinate, createdAt: Self.start,
            expiresAt: Self.start.addingTimeInterval(3600)
        ))
        clock.advance(by: 15 * 60)
        auth.use(voter)
        return (service, auth, clock)
    }

    private func stored(_ service: PlaceholderReportService) async throws -> Report? {
        try await service.reports(near: coordinate, radius: 100).first
    }

    @Test
    func aYesCountsAndRenewsTheReportForItsLifetime() async throws {
        let (service, _, clock) = try await votingService()

        #expect(try await service.confirm("r1", isStillPresent: true))
        let report = try #require(try await stored(service))
        #expect(report.confirmations == 1)
        #expect(report.expiresAt == clock.now().addingTimeInterval(ReportKind.blockedPath.lifetime))
    }

    @Test
    func aUserVotesOnlyOnceOnAReport() async throws {
        let (service, _, clock) = try await votingService()
        try await service.confirm("r1", isStillPresent: true)
        clock.advance(by: 120)

        await #expect(throws: ReportServiceError.permissionDenied) {
            try await service.confirm("r1", isStillPresent: false)
        }
        #expect(try await stored(service)?.negativeConfirmations == 0)
    }

    @Test
    func theReporterCannotVoteOnTheirOwnReport() async throws {
        let (service, _, _) = try await votingService(voter: "reporter")

        await #expect(throws: ReportServiceError.permissionDenied) {
            try await service.confirm("r1", isStillPresent: true)
        }
    }

    @Test
    func votesAreOneAMinute() async throws {
        let (service, auth, clock) = try await votingService()
        auth.use("reporter")
        try await service.submit(Report(
            id: "r2", kind: .construction, coordinate: coordinate, createdAt: Self.start,
            expiresAt: Self.start.addingTimeInterval(3600)
        ))
        auth.use("voter")
        try await service.confirm("r1", isStillPresent: true)

        await #expect(throws: ReportServiceError.rateLimited) {
            try await service.confirm("r2", isStillPresent: true)
        }
        clock.advance(by: 60)
        #expect(try await service.confirm("r2", isStillPresent: true))
    }

    @Test
    func aNoIsRefusedForTheReportsFirstTenMinutes() async throws {
        let (service, _, clock) = try await votingService()
        clock.advance(by: -15 * 60 + 9 * 60)

        await #expect(throws: ReportServiceError.permissionDenied) {
            try await service.confirm("r1", isStillPresent: false)
        }
    }

    @Test
    func aVoteNeedsASignedInUser() async throws {
        let (service, auth, _) = try await votingService()
        auth.use(nil)

        await #expect(throws: ReportServiceError.notSignedIn) {
            try await service.confirm("r1", isStillPresent: true)
        }
    }

    @Test
    func twoNoAnswersSinceTheLastYesEndTheReport() async throws {
        let (service, auth, clock) = try await votingService(voter: "a")
        try await service.confirm("r1", isStillPresent: false)
        auth.use("b")
        try await service.confirm("r1", isStillPresent: true)
        auth.use("c")
        try await service.confirm("r1", isStillPresent: false)
        #expect(try await stored(service)?.negativesSinceConfirm == 1)

        auth.use("d")
        try await service.confirm("r1", isStillPresent: false)
        #expect(try await stored(service) == nil)
        clock.advance(by: 60)
        auth.use("e")
        await #expect(throws: ReportServiceError.permissionDenied) {
            try await service.confirm("r1", isStillPresent: true)
        }
    }
}
