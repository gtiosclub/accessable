import FirebaseFirestore
import Foundation
import os
import Synchronization

private let logger = Logger(subsystem: "AccessAble", category: "Reports")

enum ReportServiceError: Error, Equatable, Sendable {
    case notSignedIn
    case permissionDenied
    case invalidReport
    /// The rules allow one report a minute for each user.
    case rateLimited
    /// The server didn't confirm in time. Firestore keeps the write and sends it once online.
    case queuedOffline
    /// The server couldn't be reached in time, and the write was not kept: a vote, which runs as a transaction.
    case unavailable
}

/// Reports in Firestore's shared `reports` collection, readable by every signed-in user.
final class FirestoreReportService: ReportService, @unchecked Sendable {
    /// The most reports one read or listener gets back. The rules refuse a list above 200.
    static let queryLimit = 200
    /// How long after one report the rules refuse the next from the same user.
    static let rateLimitWindow: TimeInterval = 60
    /// How long a submit waits for the server before saying the report is queued.
    static let commitTimeout: Duration = .seconds(10)
    /// How often the live stream drops reports that expired since the last snapshot.
    static let recheckInterval: Duration = .seconds(30)
    /// How many corners the rules allow in a report's area.
    static let areaPointLimits = 3...10

    private let auth: any AuthService
    private let database: Firestore
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    /// When this phone last sent or queued a report for each user, so the next one inside the
    /// window fails fast.
    private let lastSubmit = Mutex<[String: Date]>([:])
    /// When this phone last sent a vote for each user, likewise.
    private let lastVote = Mutex<[String: Date]>([:])

    init(
        auth: any AuthService,
        database: Firestore = Firestore.firestore(),
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.auth = auth
        self.database = database
        self.clock = clock
        self.now = now
    }

    func submit(_ report: Report) async throws {
        guard let user = await auth.currentUser() else {
            throw ReportServiceError.notSignedIn
        }
        guard Self.isValid(report, reporterID: user.id) else {
            throw ReportServiceError.invalidReport
        }
        guard !Self.isRateLimited(lastReportAt: lastSubmit.withLock { $0[user.id] }, now: now()) else {
            throw ReportServiceError.rateLimited
        }

        let reportReference = database.collection("reports").document(report.id)
        let rateLimitReference = database.collection("rateLimits").document(user.id)

        var values: [String: Any] = [
            "id": report.id,
            "kind": report.kind.rawValue,
            "coordinate": Self.dictionary(report.coordinate),
            "createdAt": FieldValue.serverTimestamp(),
            "expiresAt": Timestamp(date: report.expiresAt),
            "confirmations": 0,
            "reporterID": user.id,
            "negativeConfirmations": 0,
            "negativesSinceConfirm": 0
        ]

        if let area = report.area {
            values["area"] = area.map(Self.dictionary)
        }

        let batch = database.batch()
        batch.setData(values, forDocument: reportReference)
        batch.setData([
            "lastReportAt": FieldValue.serverTimestamp(),
            "lastReportId": report.id
        ], forDocument: rateLimitReference, merge: true)

        do {
            try await Self.commit(
                within: Self.commitTimeout,
                clock: clock,
                onLateOutcome: { error in
                    if let error {
                        logger.error("Queued report \(report.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    } else {
                        logger.notice("Queued report \(report.id, privacy: .public) reached the server")
                    }
                },
                { batch.commit(completion: $0) }
            )
        } catch ReportServiceError.queuedOffline {
            logger.notice("Report \(report.id, privacy: .public) is queued until the server answers")
            let queuedAt = now()
            lastSubmit.withLock { $0[user.id] = queuedAt }
            throw ReportServiceError.queuedOffline
        } catch {
            throw await failure(of: error, userID: user.id)
        }
        let sentAt = now()
        lastSubmit.withLock { $0[user.id] = sentAt }
    }

    func reports(
        near coordinate: GeoCoordinate,
        radius: Double
    ) async throws -> [Report] {
        guard radius.isFinite, radius >= 0 else {
            throw ReportServiceError.invalidReport
        }
        guard await auth.currentUser() != nil else {
            throw ReportServiceError.notSignedIn
        }

        let asOf = now()
        let snapshot: QuerySnapshot
        do {
            snapshot = try await unexpiredReports(asOf: asOf).getDocuments()
        } catch {
            logger.error("Report fetch failed: \(error.localizedDescription, privacy: .public)")
            throw Self.isPermissionDenied(error) ? ReportServiceError.permissionDenied : error
        }

        return Self.decode(snapshot).filter {
            $0.expiresAt > asOf && $0.isNear(coordinate, within: radius)
        }
    }

    func reportChanges(
        near coordinate: GeoCoordinate,
        radius: Double
    ) -> AsyncStream<[Report]> {
        Self.changes(near: coordinate, radius: radius, auth: auth, clock: clock, now: now) { [self] send in
            let registration = unexpiredReports(asOf: now()).addSnapshotListener { snapshot, error in
                if let error {
                    send(.failure(error))
                } else if let snapshot {
                    send(.success(Self.decode(snapshot)))
                }
            }
            let listener = ListenerHandle(registration)
            return { listener.remove() }
        }
    }

    @discardableResult
    func confirm(_ reportID: String, isStillPresent: Bool) async throws -> Bool {
        guard let user = await auth.currentUser() else {
            throw ReportServiceError.notSignedIn
        }
        guard !Self.isRateLimited(lastReportAt: lastVote.withLock { $0[user.id] }, now: now()) else {
            throw ReportServiceError.rateLimited
        }

        let reportReference = database.collection("reports").document(reportID)
        let voteReference = reportReference.collection("votes").document(user.id)
        let rateLimitReference = database.collection("rateLimits").document(user.id)
        let extended = Mutex(false)
        // The phone's clock: a yes sets the expiry from it, and the rules allow it only within
        // their clock tolerance of the server's.
        let time = now()

        do {
            try await Self.commit(
                within: Self.commitTimeout,
                clock: clock,
                onLateOutcome: { error in
                    if let error {
                        logger.error("Late vote on report \(reportID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    } else {
                        logger.notice("Late vote on report \(reportID, privacy: .public) reached the server")
                    }
                },
                { completion in
                    database.runTransaction({ transaction, errorPointer -> Any? in
                        do {
                            let snapshot = try transaction.getDocument(reportReference)
                            let vote = try transaction.getDocument(voteReference)
                            guard let data = snapshot.data(), let report = Self.decode(id: reportID, data: data) else {
                                throw ReportServiceError.invalidReport
                            }
                            guard Self.canVote(on: report, as: user.id, isStillPresent: isStillPresent, now: time),
                                  !vote.exists else {
                                throw ReportServiceError.permissionDenied
                            }
                            let change = Self.vote(on: report, isStillPresent: isStillPresent, now: time)
                            transaction.setData(
                                ["isStillPresent": isStillPresent, "votedAt": FieldValue.serverTimestamp()],
                                forDocument: voteReference
                            )
                            transaction.updateData(change.fields, forDocument: reportReference)
                            // names the report, as the rules require, so one stamp can't cover votes on several
                            transaction.setData(
                                ["lastVoteAt": FieldValue.serverTimestamp(), "lastVoteReportId": reportID],
                                forDocument: rateLimitReference, merge: true
                            )
                            return change.extends
                        } catch {
                            errorPointer?.pointee = error as NSError
                            return nil
                        }
                    }, completion: { result, error in
                        extended.withLock { $0 = result as? Bool ?? false }
                        completion(error)
                    })
                }
            )
        } catch {
            throw await voteFailure(of: error, userID: user.id, isStillPresent: isStillPresent)
        }
        let votedAt = now()
        lastVote.withLock { $0[user.id] = votedAt }
        return extended.withLock { $0 }
    }

    /// Logs why a vote failed, then names it like `failure(of:userID:)`: a refusal inside the
    /// vote stamp's window is `.rateLimited`, and no answer in time `.unavailable`, since a
    /// transaction isn't queued.
    private func voteFailure(of error: any Error, userID: String, isStillPresent: Bool) async -> any Error {
        logger.error("Report vote failed: \(error.localizedDescription, privacy: .public)")
        if let error = error as? ReportServiceError {
            return error == .queuedOffline ? ReportServiceError.unavailable : error
        }
        if Self.isUnavailable(error) { return ReportServiceError.unavailable }
        guard Self.isPermissionDenied(error) else { return error }
        let stamp = await rateLimitStamp("lastVoteAt", userID: userID) ?? lastVote.withLock { $0[userID] }
        guard !Self.isRateLimited(lastReportAt: stamp, now: now()) else { return ReportServiceError.rateLimited }
        if isStillPresent {
            // the yes's expiry is from this phone's clock, refused more than the rules' tolerance off the server's
            logger.notice("A refused yes may mean this phone's clock is off the server's")
        }
        return ReportServiceError.permissionDenied
    }

    /// Reports that haven't expired, soonest to expire first, as many as the rules allow.
    private func unexpiredReports(asOf date: Date) -> Query {
        database.collection("reports")
            .whereField("expiresAt", isGreaterThan: Timestamp(date: date))
            .order(by: "expiresAt")
            .limit(to: Self.queryLimit)
    }

    /// Logs why the commit failed, then names it: a refusal inside the rate limit window is
    /// `.rateLimited`, any other refusal `.permissionDenied`, and anything else as Firestore said.
    private func failure(of error: any Error, userID: String) async -> any Error {
        logger.error("Report submit failed: \(error.localizedDescription, privacy: .public)")
        guard Self.isPermissionDenied(error) else { return error }
        let stamp = await rateLimitStamp("lastReportAt", userID: userID) ?? lastSubmit.withLock { $0[userID] }
        return Self.isRateLimited(lastReportAt: stamp, now: now())
            ? ReportServiceError.rateLimited
            : ReportServiceError.permissionDenied
    }

    /// When the rules last counted a report or a vote from this user, from `field` of their own `rateLimits` stamp.
    private func rateLimitStamp(_ field: String, userID: String) async -> Date? {
        do {
            let snapshot = try await database.collection("rateLimits").document(userID).getDocument()
            return (snapshot.data(with: .estimate)?[field] as? Timestamp)?.dateValue()
        } catch {
            logger.error("Report rate limit read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The reports in a snapshot, read with estimated server times so this user's own pending
    /// report isn't dropped. Logs how many documents couldn't be read.
    private static func decode(_ snapshot: QuerySnapshot) -> [Report] {
        let reports = snapshot.documents.compactMap {
            decode(id: $0.documentID, data: $0.data(with: .estimate))
        }
        let skipped = snapshot.documents.count - reports.count
        if skipped > 0 {
            logger.error("Skipped \(skipped, privacy: .public) reports that couldn't be read")
        }
        if snapshot.documents.count == queryLimit {
            logger.notice("Got the query limit of \(queryLimit, privacy: .public) reports; later-expiring ones are missed")
        }
        return reports
    }

    private static func dictionary(_ coordinate: GeoCoordinate) -> [String: Double] {
        ["latitude": coordinate.latitude, "longitude": coordinate.longitude]
    }
}

// MARK: - Pure pieces, tested without Firestore

extension FirestoreReportService {
    /// The live stream behind `reportChanges`. Once signed in, `listen` starts the listener with
    /// a callback for each snapshot and returns how to stop it. The stream sends only changes,
    /// rechecks expiry between snapshots, and ends on a listener error so the caller can
    /// subscribe again.
    static func changes(
        near coordinate: GeoCoordinate,
        radius: Double,
        auth: any AuthService,
        clock: any Clock<Duration>,
        now: @escaping @Sendable () -> Date,
        listen: @escaping @Sendable (
            _ send: @escaping @Sendable (Result<[Report], any Error>) -> Void
        ) -> @Sendable () -> Void
    ) -> AsyncStream<[Report]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                guard radius.isFinite, radius >= 0 else {
                    logger.error("Report stream refused radius \(radius, privacy: .public)")
                    continuation.finish()
                    return
                }
                guard await auth.currentUser() != nil else {
                    logger.error("Report stream needs a signed-in user")
                    continuation.finish()
                    return
                }

                let feed = OSAllocatedUnfairLock(initialState: ReportFeed(coordinate: coordinate, radius: radius))
                let stop = listen { result in
                    switch result {
                    case .success(let reports):
                        let time = now()
                        // Yield under the lock, so the listener and the recheck can't send out of order.
                        feed.withLock { feed in
                            if let changed = feed.receive(reports, now: time) { continuation.yield(changed) }
                        }
                    case .failure(let error):
                        logger.error("Report listener failed: \(error.localizedDescription, privacy: .public)")
                        continuation.finish()
                    }
                }
                defer { stop() }

                while true {
                    do { try await clock.sleep(for: recheckInterval) } catch { return }
                    let time = now()
                    feed.withLock { feed in
                        if let changed = feed.refresh(now: time) { continuation.yield(changed) }
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Starts a commit and waits for it, at most `timeout`. A commit can't be cancelled, so the
    /// wait ends at whichever comes first: the commit's result, or `.queuedOffline` once the
    /// timeout passes. A result that comes after the timeout goes to `onLateOutcome`, since the
    /// server can still refuse a queued write.
    static func commit(
        within timeout: Duration,
        clock: any Clock<Duration>,
        onLateOutcome: @escaping @Sendable ((any Error)?) -> Void,
        _ start: (_ completion: @escaping @Sendable ((any Error)?) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let outcome = FirstOutcome<Void>()
            outcome.wait(continuation)
            // Not structured: nothing should wait on the commit once the timeout passes.
            outcome.cancelsOnFinish(Task {
                do { try await clock.sleep(for: timeout) } catch { return }
                outcome.finish(.failure(ReportServiceError.queuedOffline))
            })
            start { error in
                if !outcome.finish(error.map { .failure($0) } ?? .success(())) {
                    onLateOutcome(error)
                }
            }
        }
    }

    /// Whether the rules would still refuse a report, `rateLimitWindow` after the last one.
    static func isRateLimited(lastReportAt: Date?, now: Date) -> Bool {
        guard let lastReportAt else { return false }
        // The phone's clock against the server's stamp: a skewed clock can misjudge the window.
        return now.timeIntervalSince(lastReportAt) < rateLimitWindow
    }

    static func isUnavailable(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == FirestoreErrorDomain
            && [FirestoreErrorCode.unavailable.rawValue, FirestoreErrorCode.deadlineExceeded.rawValue]
                .contains(error.code)
    }

    /// How long a report is safe from "no" votes: too new for anyone to have walked past it since.
    static let denialGrace: TimeInterval = 10 * 60
    /// "No" votes since the last "yes" that end a report.
    static let removalDenials = 2

    /// What the rules check of a vote that the app can check first.
    static func canVote(on report: Report, as userID: String, isStillPresent: Bool, now: Date) -> Bool {
        report.reporterID != userID
            && report.expiresAt > now
            && (isStillPresent || now.timeIntervalSince(report.createdAt) >= denialGrace)
    }

    /// The fields a vote changes, and whether it moves the expiry later. A yes sets the expiry to
    /// one lifetime from `now` unless it is already later; the last "no" ends the report at the
    /// server's time, so every expiry filter drops it.
    static func vote(on report: Report, isStillPresent: Bool, now: Date) -> (fields: [String: Any], extends: Bool) {
        guard isStillPresent else {
            let denials = report.negativesSinceConfirm + 1
            var fields: [String: Any] = [
                "negativeConfirmations": report.negativeConfirmations + 1,
                "negativesSinceConfirm": denials
            ]
            if denials >= removalDenials { fields["expiresAt"] = FieldValue.serverTimestamp() }
            return (fields, false)
        }
        var fields: [String: Any] = ["confirmations": report.confirmations + 1, "negativesSinceConfirm": 0]
        let renewed = now.addingTimeInterval(report.kind.lifetime)
        guard renewed > report.expiresAt else { return (fields, false) }
        fields["expiresAt"] = Timestamp(date: renewed)
        return (fields, true)
    }

    static func isPermissionDenied(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == FirestoreErrorDomain
            && error.code == FirestoreErrorCode.permissionDenied.rawValue
    }

    /// What the rules check of a new report that the app can check first.
    static func isValid(_ report: Report, reporterID: String) -> Bool {
        report.reporterID == reporterID
            && report.expiresAt > report.createdAt
            && isValid(report.coordinate)
            && (report.area.map { areaPointLimits.contains($0.count) && $0.allSatisfy(isValid) } ?? true)
    }

    static func isValid(_ coordinate: GeoCoordinate) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite
            && (-90.0...90.0).contains(coordinate.latitude)
            && (-180.0...180.0).contains(coordinate.longitude)
    }

    /// A report from a document's data, or nil when any field is missing or isn't what the
    /// rules allow.
    static func decode(id documentID: String, data: [String: Any]) -> Report? {
        guard let id = data["id"] as? String,
              id == documentID,
              let kind = (data["kind"] as? String).flatMap(ReportKind.init(rawValue:)),
              let coordinate = coordinate(data["coordinate"]),
              let createdAt = data["createdAt"] as? Timestamp,
              let expiresAt = data["expiresAt"] as? Timestamp,
              let reporterID = data["reporterID"] as? String else {
            return nil
        }

        var area: [GeoCoordinate]?
        if let rawArea = data["area"], !(rawArea is NSNull) {
            guard let points = rawArea as? [Any] else { return nil }
            let corners = points.compactMap(Self.coordinate)
            guard corners.count == points.count, areaPointLimits.contains(corners.count) else { return nil }
            area = corners
        }

        return Report(
            id: id,
            kind: kind,
            coordinate: coordinate,
            area: area,
            createdAt: createdAt.dateValue(),
            expiresAt: expiresAt.dateValue(),
            confirmations: data["confirmations"] as? Int ?? 0,
            reporterID: reporterID,
            // missing on reports from before REPORT-6
            negativeConfirmations: data["negativeConfirmations"] as? Int ?? 0,
            negativesSinceConfirm: data["negativesSinceConfirm"] as? Int ?? 0
        )
    }

    private static func coordinate(_ value: Any?) -> GeoCoordinate? {
        guard let point = value as? [String: Any],
              let latitude = point["latitude"] as? Double,
              let longitude = point["longitude"] as? Double else {
            return nil
        }
        let coordinate = GeoCoordinate(latitude: latitude, longitude: longitude)
        return isValid(coordinate) ? coordinate : nil
    }
}

/// What the live stream last heard and last sent. It keeps the nearby reports from the latest
/// snapshot, so a recheck can drop the ones that expired, and stays quiet when nothing changed.
struct ReportFeed: Sendable {
    let coordinate: GeoCoordinate
    let radius: Double
    private var nearby: [Report] = []
    private var lastSent: [Report]?

    init(coordinate: GeoCoordinate, radius: Double) {
        self.coordinate = coordinate
        self.radius = radius
    }

    /// A new snapshot. Returns the reports to send, or nil when they're what was last sent.
    mutating func receive(_ reports: [Report], now: Date) -> [Report]? {
        nearby = reports.filter { $0.isNear(coordinate, within: radius) }
        return refresh(now: now)
    }

    /// Drops the reports that have expired. Returns the reports to send, or nil when unchanged.
    mutating func refresh(now: Date) -> [Report]? {
        nearby.removeAll { $0.expiresAt <= now }
        guard nearby != lastSent else { return nil }
        lastSent = nearby
        return nearby
    }
}
