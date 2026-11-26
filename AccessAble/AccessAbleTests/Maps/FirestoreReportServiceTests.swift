import FirebaseFirestore
import Foundation
import Synchronization
import Testing
@testable import AccessAble

private let created = Date(timeIntervalSince1970: 1_700_000_000)
private let here = GeoCoordinate(latitude: 33.7756, longitude: -84.3963)
/// About 111 m due north of `here`.
private let north = GeoCoordinate(latitude: 33.7766, longitude: -84.3963)
private let far = GeoCoordinate(latitude: 34.0, longitude: -84.0)

private func report(
    id: String = "r1",
    at coordinate: GeoCoordinate = here,
    area: [GeoCoordinate]? = nil,
    expiresIn lifetime: TimeInterval = 3600
) -> Report {
    Report(
        id: id, kind: .construction, coordinate: coordinate, area: area,
        createdAt: created, expiresAt: created.addingTimeInterval(lifetime), reporterID: "user"
    )
}

private func point(_ coordinate: GeoCoordinate) -> [String: Any] {
    ["latitude": coordinate.latitude, "longitude": coordinate.longitude]
}

/// A report document as Firestore stores it.
private func document(area: Any? = nil) -> [String: Any] {
    var data: [String: Any] = [
        "id": "r1",
        "kind": "construction",
        "coordinate": point(here),
        "createdAt": Timestamp(date: created),
        "expiresAt": Timestamp(date: created.addingTimeInterval(3600)),
        "confirmations": 2,
        "reporterID": "user"
    ]
    if let area { data["area"] = area }
    return data
}

/// A time the test sets by hand.
private final class TestTime: Sendable {
    private let value = Mutex(created)
    var now: Date { value.withLock { $0 } }
    func set(_ date: Date) { value.withLock { $0 = date } }
}

/// Stands in for the Firestore listener: the test sends its snapshots and sees it removed.
private final class FakeListener: Sendable {
    private let sender = Mutex<(@Sendable (Result<[Report], any Error>) -> Void)?>(nil)
    let removals: AsyncStream<Void>
    private let removed: AsyncStream<Void>.Continuation
    private let started = Mutex(false)

    init() {
        (removals, removed) = AsyncStream.makeStream()
    }

    var wasStarted: Bool { started.withLock { $0 } }

    func listen(_ send: @escaping @Sendable (Result<[Report], any Error>) -> Void) -> @Sendable () -> Void {
        started.withLock { $0 = true }
        sender.withLock { $0 = send }
        return { [removed] in removed.yield() }
    }

    func send(_ result: Result<[Report], any Error>) {
        sender.withLock { $0 }?(result)
    }
}

/// Holds a commit's completion so the test decides when, or whether, the server answers.
private final class HeldCommit: Sendable {
    private let completion = Mutex<(@Sendable ((any Error)?) -> Void)?>(nil)
    private let holds: AsyncStream<Void>
    private let held: AsyncStream<Void>.Continuation

    init() {
        (holds, held) = AsyncStream.makeStream()
        (lateOutcomes, lateOutcome) = AsyncStream.makeStream()
    }

    func hold(_ completion: @escaping @Sendable ((any Error)?) -> Void) {
        self.completion.withLock { $0 = completion }
        held.yield()
    }

    /// What arrived after the timeout, in order: nil for a success.
    let lateOutcomes: AsyncStream<(any Error)?>
    private let lateOutcome: AsyncStream<(any Error)?>.Continuation

    func late(_ error: (any Error)?) {
        lateOutcome.yield(error)
    }

    func finishLateOutcomes() {
        lateOutcome.finish()
    }

    /// Returns once the commit has started.
    func waitForCommit() async {
        var holds = holds.makeAsyncIterator()
        await holds.next()
    }

    func complete(_ error: (any Error)?) {
        completion.withLock { $0 }?(error)
    }
}

private struct Boom: Error, Equatable {}

struct FirestoreReportServiceTests {
    // MARK: Decoding

    @Test
    func decodesAStoredReport() {
        var expected = report()
        expected.confirmations = 2
        #expect(FirestoreReportService.decode(id: "r1", data: document()) == expected)
    }

    @Test
    func decodesAnArea() {
        let corners = [here, north, far]
        let decoded = FirestoreReportService.decode(id: "r1", data: document(area: corners.map(point)))
        #expect(decoded?.area == corners)
    }

    @Test
    func aNullAreaIsNoArea() throws {
        let decoded = try #require(FirestoreReportService.decode(id: "r1", data: document(area: NSNull())))
        #expect(decoded.area == nil)
    }

    @Test
    func missingConfirmationsAreNone() {
        var data = document()
        data["confirmations"] = nil
        #expect(FirestoreReportService.decode(id: "r1", data: data)?.confirmations == 0)
    }

    /// Reports from before REPORT-6 have no denial counts.
    @Test
    func missingDenialsAreNone() throws {
        var data = document()
        data["negativeConfirmations"] = nil
        data["negativesSinceConfirm"] = nil
        let decoded = try #require(FirestoreReportService.decode(id: "r1", data: data))
        #expect(decoded.negativeConfirmations == 0)
        #expect(decoded.negativesSinceConfirm == 0)
    }

    @Test
    func decodesTheDenials() throws {
        var data = document()
        data["negativeConfirmations"] = 3
        data["negativesSinceConfirm"] = 1
        let decoded = try #require(FirestoreReportService.decode(id: "r1", data: data))
        #expect(decoded.negativeConfirmations == 3)
        #expect(decoded.negativesSinceConfirm == 1)
    }

    // MARK: Votes

    @Test
    func aYesCountsAndRenewsTheExpiryFromNow() throws {
        let now = created.addingTimeInterval(1800)
        let change = FirestoreReportService.vote(on: report(), isStillPresent: true, now: now)
        #expect(change.extends)
        #expect(change.fields["confirmations"] as? Int == 1)
        #expect(change.fields["negativesSinceConfirm"] as? Int == 0)
        let expiry = try #require(change.fields["expiresAt"] as? Timestamp)
        #expect(expiry.dateValue() == now.addingTimeInterval(ReportKind.construction.lifetime))
    }

    /// The rules refuse a vote that shortens a report.
    @Test
    func aYesNeverShortensTheExpiry() {
        let lasting = report(expiresIn: 20 * 24 * 60 * 60)
        let change = FirestoreReportService.vote(on: lasting, isStillPresent: true, now: created)
        #expect(!change.extends)
        #expect(change.fields["expiresAt"] == nil)
        #expect(change.fields["confirmations"] as? Int == 1)
    }

    @Test
    func aFirstNoCountsAndKeepsTheExpiry() {
        let change = FirestoreReportService.vote(on: report(), isStillPresent: false, now: created)
        #expect(!change.extends)
        #expect(change.fields["negativeConfirmations"] as? Int == 1)
        #expect(change.fields["negativesSinceConfirm"] as? Int == 1)
        #expect(change.fields["expiresAt"] == nil)
    }

    @Test
    func theSecondNoSinceAYesEndsTheReportAtTheServersTime() {
        var denied = report()
        denied.negativeConfirmations = 3
        denied.negativesSinceConfirm = 1
        let change = FirestoreReportService.vote(on: denied, isStillPresent: false, now: created)
        #expect(change.fields["negativeConfirmations"] as? Int == 4)
        #expect(change.fields["negativesSinceConfirm"] as? Int == 2)
        #expect(change.fields["expiresAt"] is FieldValue)
    }

    @Test
    func votesTheRulesRefuseAreRefusedFirst() {
        let live = report()
        #expect(FirestoreReportService.canVote(on: live, as: "other", isStillPresent: true, now: created))
        #expect(!FirestoreReportService.canVote(on: live, as: "user", isStillPresent: true, now: created))
        #expect(!FirestoreReportService.canVote(
            on: live, as: "other", isStillPresent: true, now: live.expiresAt
        ))
        // a no waits ten minutes after the report is made
        #expect(!FirestoreReportService.canVote(
            on: live, as: "other", isStillPresent: false, now: created.addingTimeInterval(599)
        ))
        #expect(FirestoreReportService.canVote(
            on: live, as: "other", isStillPresent: false, now: created.addingTimeInterval(600)
        ))
    }

    @Test(arguments: ["id", "kind", "coordinate", "createdAt", "expiresAt", "reporterID"])
    func skipsADocumentMissing(_ field: String) {
        var data = document()
        data[field] = nil
        #expect(FirestoreReportService.decode(id: "r1", data: data) == nil)
    }

    @Test
    func skipsADocumentWhoseIDDiffers() {
        #expect(FirestoreReportService.decode(id: "other", data: document()) == nil)
    }

    @Test
    func skipsAnUnknownKind() {
        var data = document()
        data["kind"] = "pothole"
        #expect(FirestoreReportService.decode(id: "r1", data: data) == nil)
    }

    @Test
    func skipsABadCoordinate() {
        let coordinates: [[String: Any]] = [
            ["latitude": 91.0, "longitude": 0.0],
            ["latitude": 0.0, "longitude": -181.0],
            ["latitude": 0.0],
            ["latitude": "north", "longitude": 0.0],
        ]
        for coordinate in coordinates {
            var data = document()
            data["coordinate"] = coordinate
            #expect(FirestoreReportService.decode(id: "r1", data: data) == nil, "\(coordinate)")
        }
    }

    @Test
    func skipsABadArea() {
        let areas: [Any] = [
            [point(here), point(north)],
            Array(repeating: point(here), count: 11),
            [point(here), point(north), ["latitude": 91.0, "longitude": 0.0]],
            "not a list",
        ]
        for area in areas {
            #expect(FirestoreReportService.decode(id: "r1", data: document(area: area)) == nil, "\(area)")
        }
    }

    // MARK: Nearness

    @Test
    func nearIncludesTheRadiusEdge() {
        let edge = GeoMath.distance(from: here, to: north)
        #expect(report(at: north).isNear(here, within: edge))
        #expect(!report(at: north).isNear(here, within: edge - 0.01))
    }

    @Test
    func aCornerOfTheAreaCountsAsNear() {
        let spread = report(at: far, area: [far, north, far])
        #expect(spread.isNear(here, within: 200))
        #expect(!spread.isNear(here, within: 100))
    }

    // MARK: Validation

    @Test
    func acceptsAReportTheRulesAllow() {
        #expect(FirestoreReportService.isValid(report(), reporterID: "user"))
        #expect(FirestoreReportService.isValid(report(area: [here, north, far]), reporterID: "user"))
    }

    @Test(arguments: [
        report(area: [here, north]),
        report(area: Array(repeating: here, count: 11)),
        report(area: [here, north, GeoCoordinate(latitude: 91, longitude: 0)]),
        report(at: GeoCoordinate(latitude: .nan, longitude: 0)),
        report(expiresIn: 0),
    ])
    func refusesAReportTheRulesWould(_ report: Report) {
        #expect(!FirestoreReportService.isValid(report, reporterID: "user"))
    }

    @Test
    func refusesSomeoneElsesReport() {
        #expect(!FirestoreReportService.isValid(report(), reporterID: "someone else"))
    }

    // MARK: Rate limit

    @Test
    func rateLimitLastsAMinute() {
        let window = FirestoreReportService.rateLimitWindow
        #expect(window == 60)
        #expect(!FirestoreReportService.isRateLimited(lastReportAt: nil, now: created))
        #expect(FirestoreReportService.isRateLimited(lastReportAt: created, now: created.addingTimeInterval(window - 1)))
        #expect(!FirestoreReportService.isRateLimited(lastReportAt: created, now: created.addingTimeInterval(window)))
    }

    @Test
    func onlyFirestoresRefusalIsPermissionDenied() {
        let denied = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.permissionDenied.rawValue)
        let unavailable = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.unavailable.rawValue)
        let elsewhere = NSError(domain: NSURLErrorDomain, code: FirestoreErrorCode.permissionDenied.rawValue)
        #expect(FirestoreReportService.isPermissionDenied(denied))
        #expect(!FirestoreReportService.isPermissionDenied(unavailable))
        #expect(!FirestoreReportService.isPermissionDenied(elsewhere))
    }

    @Test
    func onlyFirestoresUnreachableServerIsUnavailable() {
        let unavailable = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.unavailable.rawValue)
        let late = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.deadlineExceeded.rawValue)
        let denied = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.permissionDenied.rawValue)
        let elsewhere = NSError(domain: NSURLErrorDomain, code: FirestoreErrorCode.unavailable.rawValue)
        #expect(FirestoreReportService.isUnavailable(unavailable))
        #expect(FirestoreReportService.isUnavailable(late))
        #expect(!FirestoreReportService.isUnavailable(denied))
        #expect(!FirestoreReportService.isUnavailable(elsewhere))
    }

    // MARK: Feed

    @Test
    func theFeedSendsTheFirstSnapshotEvenIfEmpty() {
        var feed = ReportFeed(coordinate: here, radius: 100)
        #expect(feed.receive([], now: created) == [])
        #expect(feed.receive([], now: created) == nil)
    }

    @Test
    func theFeedSkipsARepeatAndSendsAChange() {
        var feed = ReportFeed(coordinate: here, radius: 100)
        let first = report(id: "a")
        let second = report(id: "b")
        #expect(feed.receive([first], now: created) == [first])
        #expect(feed.receive([first], now: created) == nil)
        #expect(feed.receive([first, second], now: created) == [first, second])
    }

    @Test
    func theFeedKeepsOnlyNearbyUnexpiredReports() {
        var feed = ReportFeed(coordinate: here, radius: 100)
        let near = report(id: "near")
        let away = report(id: "far", at: far)
        let expired = report(id: "expired", expiresIn: 10)
        #expect(feed.receive([near, away, expired], now: created.addingTimeInterval(10)) == [near])
    }

    @Test
    func aRecheckDropsAReportThatExpired() {
        var feed = ReportFeed(coordinate: here, radius: 100)
        let lasting = report(id: "lasting")
        let brief = report(id: "brief", expiresIn: 10)
        #expect(feed.receive([lasting, brief], now: created) == [lasting, brief])
        #expect(feed.refresh(now: created.addingTimeInterval(9)) == nil)
        #expect(feed.refresh(now: created.addingTimeInterval(10)) == [lasting])
        #expect(feed.refresh(now: created.addingTimeInterval(11)) == nil)
    }

    // MARK: Live stream

    private func changes(
        listener: FakeListener,
        clock: ManualClock = ManualClock(),
        time: TestTime = TestTime(),
        signedIn: Bool = true,
        radius: Double = 100
    ) -> AsyncStream<[Report]> {
        FirestoreReportService.changes(
            near: here, radius: radius, auth: PlaceholderAuthService(signedIn: signedIn),
            clock: clock, now: { time.now }, listen: listener.listen
        )
    }

    @Test(.timeLimit(.minutes(1)), arguments: [(false, 100.0), (true, -1.0), (true, .infinity)])
    func theStreamEndsWithoutListeningWhenItCant(signedIn: Bool, radius: Double) async {
        let listener = FakeListener()
        var reports = changes(listener: listener, signedIn: signedIn, radius: radius).makeAsyncIterator()

        #expect(await reports.next() == nil)
        #expect(!listener.wasStarted)
    }

    /// A repeat isn't sent: had it been, it would come before the end.
    @Test(.timeLimit(.minutes(1)))
    func theStreamSendsChangesOnlyAndEndsOnAnError() async throws {
        let listener = FakeListener()
        let clock = ManualClock()
        var reports = changes(listener: listener, clock: clock).makeAsyncIterator()
        try await clock.waitForSleepers(1)

        listener.send(.success([report()]))
        #expect(await reports.next() == [report()])
        listener.send(.success([report()]))
        listener.send(.failure(Boom()))

        #expect(await reports.next() == nil)
        var removals = listener.removals.makeAsyncIterator()
        await removals.next()
    }

    @Test(.timeLimit(.minutes(1)))
    func theStreamDropsAReportOnceItExpires() async throws {
        let listener = FakeListener()
        let clock = ManualClock()
        let time = TestTime()
        var reports = changes(listener: listener, clock: clock, time: time).makeAsyncIterator()
        try await clock.waitForSleepers(1)

        listener.send(.success([report(expiresIn: 10)]))
        #expect(await reports.next() == [report(expiresIn: 10)])

        time.set(created.addingTimeInterval(10))
        clock.advance(by: FirestoreReportService.recheckInterval)
        #expect(await reports.next() == [])
    }

    @Test(.timeLimit(.minutes(1)))
    func stoppingTheStreamRemovesTheListener() async throws {
        let listener = FakeListener()
        let clock = ManualClock()
        let stream = changes(listener: listener, clock: clock)
        let consumer = Task { for await _ in stream {} }
        try await clock.waitForSleepers(1)

        consumer.cancel()

        var removals = listener.removals.makeAsyncIterator()
        await removals.next()
    }

    // MARK: Commit timeout

    @Test(.timeLimit(.minutes(1)))
    func aCommitThatAnswersReturns() async throws {
        try await FirestoreReportService.commit(within: .seconds(10), clock: ManualClock(), onLateOutcome: { _ in }) { $0(nil) }
    }

    @Test(.timeLimit(.minutes(1)))
    func aCommitThatFailsThrowsItsError() async {
        await #expect(throws: Boom()) {
            try await FirestoreReportService.commit(within: .seconds(10), clock: ManualClock(), onLateOutcome: { _ in }) { $0(Boom()) }
        }
    }

    /// The server's answer after the timeout goes to `onLateOutcome`, not a second resume.
    @Test(.timeLimit(.minutes(1)))
    func aCommitWithoutAnAnswerIsQueuedAfterTheTimeout() async throws {
        let clock = ManualClock()
        let held = HeldCommit()
        let commit = Task {
            try await FirestoreReportService.commit(within: .seconds(10), clock: clock, onLateOutcome: held.late) { held.hold($0) }
        }
        try await clock.waitForSleepers(1)

        clock.advance(by: .seconds(10))

        await #expect(throws: ReportServiceError.queuedOffline) { try await commit.value }
        held.complete(Boom())
        held.complete(nil)

        var late = held.lateOutcomes.makeAsyncIterator()
        #expect(try #require(await late.next()) is Boom)
        #expect(try #require(await late.next()) == nil)
    }

    /// Once the server answers, the timeout is cancelled and can't resume again.
    @Test(.timeLimit(.minutes(1)))
    func anAnswerBeforeTheTimeoutWins() async throws {
        let clock = ManualClock()
        let held = HeldCommit()
        let commit = Task {
            try await FirestoreReportService.commit(within: .seconds(10), clock: clock, onLateOutcome: held.late) { held.hold($0) }
        }
        try await clock.waitForSleepers(1)
        await held.waitForCommit()

        held.complete(nil)

        try await commit.value
        clock.advance(by: .seconds(10))
        held.finishLateOutcomes()

        var late = held.lateOutcomes.makeAsyncIterator()
        #expect(await late.next() == nil)
    }
}
