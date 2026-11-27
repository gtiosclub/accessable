import FirebaseFirestore
import Foundation

/// Owner: Calls (VOLUNTEER-6; progress and failure kinds from VOLUNTEER-7).
/// Matching with no Cloud Functions: each step is a Firestore transaction in the app, and
/// firebase/firestore.rules enforce every step (see the race tests in firebase/tests/calls.test.js,
/// whose helpers write exactly what this file writes).
/// LiveKit tokens come only from the getCallToken Worker.
struct FirestoreCallSignaling: CallSignaling {
    /// How long one volunteer rings before the caller skips to the next.
    static let ringTimeout: Duration = .seconds(30)
    /// A ring older than this is free for the next caller. Must match firestore.rules.
    static let staleRingAfter: TimeInterval = 45

    let auth: any AuthService
    let tokenURL: URL?

    // MARK: - Caller

    func requestCall(
        preferring preferredID: String?,
        progress: @Sendable (CallRequestProgress) -> Void
    ) async throws -> CallTicket {
        guard tokenURL != nil else { throw CallSignalingError.notConfigured }
        do {
            return try await ringUntilAnswered(preferring: preferredID, progress: progress)
        } catch let error where Self.isOffline(error) {
            throw CallSignalingError.offline
        }
    }

    private func ringUntilAnswered(
        preferring preferredID: String?,
        progress: @Sendable (CallRequestProgress) -> Void
    ) async throws -> CallTicket {
        guard let me = await auth.currentUser()?.id else { throw CallSignalingError.signedOut }
        guard try await FirestoreCallSafety(auth: auth).hasConsent() else { throw CallSafetyError.consentRequired }
        var tried: Set<String> = [me]
        var attempts = 0
        var lastMiss: CallRequestProgress.Miss?

        while true {
            try Task.checkCancellation()
            let candidates = try await freeVolunteers(excluding: tried, preferring: preferredID)
            guard !candidates.isEmpty else {
                // Nobody online at all, or everyone we rang declined or didn't answer.
                throw attempts == 0 ? CallSignalingError.noVolunteers : CallSignalingError.nobodyAnswered
            }

            // Ring the first one who is still free; someone else may have rung them a moment ago.
            var ringing: String?
            for volunteerID in candidates {
                tried.insert(volunteerID)
                if let callID = try await ring(volunteerID, from: me) {
                    ringing = callID
                    break
                }
            }
            guard let callID = ringing else { continue }
            attempts += 1
            if let lastMiss { progress(.tryingNext(after: lastMiss)) }
            progress(.ringing(attempt: attempts))

            let answer: Answer
            do {
                answer = try await waitForAnswer(callID: callID)
            } catch {
                // The caller left the screen while it was ringing: stop ringing that volunteer.
                await endCall(callID: callID)
                throw error
            }

            switch answer {
            case .accepted:
                return try await acceptedTicket(for: callID)
            case .notAnswered:
                lastMiss = .declined
            case .timedOut:
                do {
                    try await skip(callID: callID)
                } catch CallSignalingError.callAccepted {
                    // They picked up just as the 30 seconds ran out: join instead of skipping.
                    return try await acceptedTicket(for: callID)
                } catch {
                    // The skip itself failed. Stop ringing them, then move on, or stop if
                    // the caller left or went offline.
                    await endCall(callID: callID)
                    if error is CancellationError || Self.isOffline(error) { throw error }
                }
                lastMiss = .noAnswer
            }
        }
    }

    func skip(callID: String) async throws {
        let db = Firestore.firestore()
        let callRef = db.collection("calls").document(callID)
        let outcome = try await db.runTransaction { transaction, errorPointer -> Any? in
            do {
                let call = try transaction.getDocument(callRef).data() ?? [:]
                guard call["status"] as? String == "ringing" else {
                    return call["status"] as? String == "accepted" ? "accepted" : "finished"
                }
                guard let volunteerID = call["volunteerId"] as? String else { return "finished" }
                let volunteerRef = db.collection("volunteers").document(volunteerID)
                let volunteer = try transaction.getDocument(volunteerRef).data() ?? [:]
                transaction.updateData(
                    ["status": "skipped", "updatedAt": FieldValue.serverTimestamp()], forDocument: callRef)
                if volunteer["ringingCallId"] as? String == callID {
                    transaction.updateData(
                        ["ringingCallId": NSNull(), "ringingSince": NSNull()], forDocument: volunteerRef)
                }
                return "skipped"
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        } as? String
        if outcome == "accepted" { throw CallSignalingError.callAccepted }
    }

    // MARK: - Volunteer

    func accept(callID: String) async throws -> CallTicket {
        guard tokenURL != nil else { throw CallSignalingError.notConfigured }
        guard let me = await auth.currentUser()?.id else { throw CallSignalingError.signedOut }
        let db = Firestore.firestore()
        let callRef = db.collection("calls").document(callID)
        let meRef = db.collection("volunteers").document(me)
        let outcome = try await db.runTransaction { transaction, errorPointer -> Any? in
            do {
                let call = try transaction.getDocument(callRef).data() ?? [:]
                let mine = try transaction.getDocument(meRef).data() ?? [:]
                // Still ringing, and still ringing *me* (a skip or another caller may have won).
                guard call["status"] as? String == "ringing",
                      call["volunteerId"] as? String == me,
                      mine["ringingCallId"] as? String == callID else { return "taken" }
                // acceptedAt is when the call began, for call history (HISTORY-1).
                transaction.updateData([
                    "status": "accepted", "updatedAt": FieldValue.serverTimestamp(),
                    "acceptedAt": FieldValue.serverTimestamp(),
                ], forDocument: callRef)
                transaction.updateData([
                    "inCall": true, "ringingCallId": NSNull(), "ringingSince": NSNull(),
                    "lastSeen": FieldValue.serverTimestamp(),
                ], forDocument: meRef)
                return "accepted"
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        } as? String
        guard outcome == "accepted" else { throw CallSignalingError.callTaken }
        return try await ticket(for: callID)
    }

    func decline(callID: String) async throws {
        guard let me = await auth.currentUser()?.id else { throw CallSignalingError.signedOut }
        let db = Firestore.firestore()
        let callRef = db.collection("calls").document(callID)
        let meRef = db.collection("volunteers").document(me)
        _ = try await db.runTransaction { transaction, errorPointer -> Any? in
            do {
                let call = try transaction.getDocument(callRef).data() ?? [:]
                let mine = try transaction.getDocument(meRef).data() ?? [:]
                if call["status"] as? String == "ringing", call["volunteerId"] as? String == me {
                    transaction.updateData(
                        ["status": "declined", "updatedAt": FieldValue.serverTimestamp()], forDocument: callRef)
                }
                if mine["ringingCallId"] as? String == callID {
                    transaction.updateData([
                        "ringingCallId": NSNull(), "ringingSince": NSNull(),
                        "lastSeen": FieldValue.serverTimestamp(),
                    ], forDocument: meRef)
                }
                return nil
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        }
    }

    // MARK: - Volunteer calling a caller (CALLBACK-1)

    func callCaller(_ callerID: String) async throws -> CallTicket {
        guard tokenURL != nil else { throw CallSignalingError.notConfigured }
        guard let me = await auth.currentUser()?.id else { throw CallSignalingError.signedOut }
        let callRef = Firestore.firestore().collection("calls").document()
        let callID = callRef.documentID
        do {
            // The rules check the two have saved each other and nobody is blocked.
            try await callRef.setData([
                "callerId": callerID, "volunteerId": me, "status": "ringing", "roomName": "call-\(callID)",
                "createdAt": FieldValue.serverTimestamp(), "updatedAt": FieldValue.serverTimestamp(),
                "startedBy": "volunteer",
            ])
        } catch let error where Self.isOffline(error) {
            throw CallSignalingError.offline
        }
        let answer: Answer
        do {
            answer = try await waitForAnswer(callID: callID)
        } catch {
            await endCall(callID: callID)
            throw error
        }
        switch answer {
        case .accepted:
            return try await acceptedTicket(for: callID)
        case .notAnswered:
            throw CallSignalingError.nobodyAnswered
        case .timedOut:
            await endCall(callID: callID)
            throw CallSignalingError.nobodyAnswered
        }
    }

    func volunteerRings(callerID: String) -> AsyncThrowingStream<[VolunteerRing], Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // Equality filters only, so Firestore needs no composite index.
            let registration = Firestore.firestore().collection("calls")
                .whereField("callerId", isEqualTo: callerID)
                .whereField("status", isEqualTo: "ringing")
                .whereField("startedBy", isEqualTo: "volunteer")
                .limit(to: 5)
                .addSnapshotListener { snapshot, error in
                    if let error { continuation.finish(throwing: error); return }
                    guard let snapshot else { return }
                    let rings = snapshot.documents.compactMap { document -> VolunteerRing? in
                        let data = document.data(with: .estimate)
                        guard let volunteer = data["volunteerId"] as? String,
                              let created = (data["createdAt"] as? Timestamp)?.dateValue() else { return nil }
                        return VolunteerRing(id: document.documentID, volunteerID: volunteer, createdAt: created)
                    }
                    continuation.yield(rings.sorted { $0.createdAt > $1.createdAt })
                }
            let listener = CallListenerHandle(registration)
            continuation.onTermination = { _ in listener.remove() }
        }
    }

    func answerVolunteerRing(callID: String) async throws -> CallTicket {
        guard let me = await auth.currentUser()?.id else { throw CallSignalingError.signedOut }
        let db = Firestore.firestore()
        let callRef = db.collection("calls").document(callID)
        let outcome = try await db.runTransaction { transaction, errorPointer -> Any? in
            do {
                let call = try transaction.getDocument(callRef).data() ?? [:]
                guard call["status"] as? String == "ringing", call["callerId"] as? String == me,
                      call["startedBy"] as? String == "volunteer" else { return "taken" }
                transaction.updateData([
                    "status": "accepted", "updatedAt": FieldValue.serverTimestamp(),
                    "acceptedAt": FieldValue.serverTimestamp(),
                ], forDocument: callRef)
                return "accepted"
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        } as? String
        guard outcome == "accepted" else { throw CallSignalingError.callTaken }
        return try await ticket(for: callID)
    }

    func declineVolunteerRing(callID: String) async throws {
        try await Firestore.firestore().collection("calls").document(callID)
            .updateData(["status": "declined", "updatedAt": FieldValue.serverTimestamp()])
    }

    // MARK: - Either side

    /// Hangs up, or gives up while still ringing. Never throws: a failed write just leaves the
    /// ring to go stale after 45 seconds.
    func endCall(callID: String) async {
        guard let me = await auth.currentUser()?.id else { return }
        let db = Firestore.firestore()
        let callRef = db.collection("calls").document(callID)
        _ = try? await db.runTransaction { transaction, errorPointer -> Any? in
            do {
                let call = try transaction.getDocument(callRef).data() ?? [:]
                guard let status = call["status"] as? String,
                      let callerID = call["callerId"] as? String,
                      let volunteerID = call["volunteerId"] as? String else { return nil }
                let volunteerRef = db.collection("volunteers").document(volunteerID)
                let volunteer = try transaction.getDocument(volunteerRef).data() ?? [:]
                let ended: [String: Any] = ["status": "ended", "updatedAt": FieldValue.serverTimestamp()]

                if me == callerID {
                    guard status == "ringing" || status == "accepted" else { return nil }
                    transaction.updateData(ended, forDocument: callRef)
                    if volunteer["ringingCallId"] as? String == callID {
                        transaction.updateData(
                            ["ringingCallId": NSNull(), "ringingSince": NSNull()], forDocument: volunteerRef)
                    }
                } else if me == volunteerID {
                    if status == "accepted" { transaction.updateData(ended, forDocument: callRef) }
                    if status == "ringing" {
                        transaction.updateData(
                            ["status": "declined", "updatedAt": FieldValue.serverTimestamp()], forDocument: callRef)
                    }
                    // Free again for the next caller.
                    if volunteer["inCall"] as? Bool == true || volunteer["ringingCallId"] as? String == callID {
                        transaction.updateData([
                            "inCall": false, "ringingCallId": NSNull(), "ringingSince": NSNull(),
                            "lastSeen": FieldValue.serverTimestamp(),
                        ], forDocument: volunteerRef)
                    }
                }
                return nil
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        }
    }

    // MARK: - Ringing

    private enum Answer { case accepted, notAnswered, timedOut }

    /// Online volunteers who can be rung now, `preferredID` first, then the most recently seen.
    private func freeVolunteers(excluding tried: Set<String>, preferring preferredID: String?) async throws -> [String] {
        // The rules require a limit of at most 100. One equality filter needs no index.
        // From the server, so being offline fails here instead of returning an old cached list.
        let snapshot = try await Firestore.firestore().collection("volunteers")
            .whereField("isOnline", isEqualTo: true)
            .limit(to: 100)
            .getDocuments(source: .server)
        guard let me = await auth.currentUser()?.id else { throw CallSignalingError.signedOut }
        let blocks = try await Firestore.firestore().collection("users").document(me)
            .collection("blockedVolunteers").getDocuments(source: .server)
        let blockedIDs = Set(blocks.documents.map(\.documentID))
        let now = Date()
        return snapshot.documents
            .compactMap { Volunteer(id: $0.documentID, firestoreData: $0.data()) }
            .filter { !tried.contains($0.id) && !blockedIDs.contains($0.id) && $0.isFreeToRing(at: now) }
            .sorted { a, b in
                if (a.id == preferredID) != (b.id == preferredID) { return a.id == preferredID }
                return a.lastSeen > b.lastSeen
            }
            .map(\.id)
    }

    /// One transaction: check the volunteer is still free, create the call, mark them ringing.
    /// Returns the new call's ID, or nil if someone else got to them first.
    private func ring(_ volunteerID: String, from me: String) async throws -> String? {
        let db = Firestore.firestore()
        let callRef = db.collection("calls").document()
        let volunteerRef = db.collection("volunteers").document(volunteerID)
        let callID = callRef.documentID
        do {
            let outcome = try await db.runTransaction { transaction, errorPointer -> Any? in
                do {
                    // Re-read the block in the transaction: a concurrent block must win over an
                    // earlier directory snapshot/preferred pick.
                    let block = try transaction.getDocument(db.collection("users").document(me)
                        .collection("blockedVolunteers").document(volunteerID))
                    guard !block.exists else { return "busy" }
                    let data = try transaction.getDocument(volunteerRef).data() ?? [:]
                    guard let volunteer = Volunteer(id: volunteerID, firestoreData: data),
                          volunteer.isFreeToRing() else { return "busy" }
                    // A volunteer cannot read the caller's private users doc. Project only
                    // the first name into the participant-only call; rules verify it.
                    let profile = try transaction.getDocument(db.collection("users").document(me)).data()
                    var callData: [String: Any] = [
                        "callerId": me,
                        "volunteerId": volunteerID,
                        "status": "ringing",
                        "roomName": "call-\(callID)",
                        "createdAt": FieldValue.serverTimestamp(),
                        "updatedAt": FieldValue.serverTimestamp(),
                    ]
                    // Left out when the rules would refuse it (no first word, or over 80 characters);
                    // the volunteer then sees "Caller".
                    if let name = profile?["displayName"] as? String,
                       !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let first = IncomingCall.firstName(from: name)
                        if first.unicodeScalars.count <= 80 { callData["callerFirstName"] = first }
                    }
                    transaction.setData(callData, forDocument: callRef)
                    // ringingSince is the server's clock, never the phone's; the rules require it.
                    transaction.updateData(
                        ["ringingCallId": callID, "ringingSince": FieldValue.serverTimestamp()],
                        forDocument: volunteerRef)
                    return "rang"
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
            } as? String
            return outcome == "rang" ? callID : nil
        } catch let error as NSError
                    where error.domain == FirestoreErrorDomain
                    && [FirestoreErrorCode.permissionDenied.rawValue, FirestoreErrorCode.aborted.rawValue]
                        .contains(error.code) {
            // The rules refused (they're ringing or went offline a moment ago): try the next one.
            // Anything else, like being offline, is the caller's problem, not a busy volunteer.
            return nil
        }
    }

    /// Waits until the volunteer answers, declines, or `ringTimeout` passes.
    /// Not a call status: tells waitForAnswer the listener stopped working.
    private static let listenerFailed = "listener-failed"

    private func waitForAnswer(callID: String) async throws -> Answer {
        let ref = Firestore.firestore().collection("calls").document(callID)
        let statuses = AsyncStream<String>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let registration = ref.addSnapshotListener { snapshot, error in
                // Without the listener we'd sit out the whole 30 seconds; go straight to the
                // skip, whose transaction reads the real status (and joins if they accepted).
                if error != nil { continuation.yield(Self.listenerFailed); continuation.finish(); return }
                if let status = snapshot?.data()?["status"] as? String { continuation.yield(status) }
            }
            let listener = CallListenerHandle(registration)
            continuation.onTermination = { _ in listener.remove() }
        }
        return try await withThrowingTaskGroup(of: Answer.self) { group in
            group.addTask {
                for await status in statuses where status != "ringing" {
                    if status == Self.listenerFailed { return .timedOut }
                    return status == "accepted" ? .accepted : .notAnswered
                }
                try Task.checkCancellation()
                return .notAnswered
            }
            group.addTask {
                try await Task.sleep(for: Self.ringTimeout)
                return .timedOut
            }
            guard let first = try await group.next() else { return .notAnswered }
            group.cancelAll()
            return first
        }
    }

    /// No connection: Firestore can't reach its server, or the request to the Worker couldn't get through.
    private static func isOffline(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == FirestoreErrorDomain {
            return error.code == FirestoreErrorCode.unavailable.rawValue
        }
        if error.domain == NSURLErrorDomain {
            return [
                NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDataNotAllowed,
            ].contains(error.code)
        }
        return false
    }

    // MARK: - Token Worker

    /// The call is accepted, so if the token can't be fetched the call must be ended here:
    /// the caller never gets a ticket to hang up with, and the volunteer would stay in the call.
    private func acceptedTicket(for callID: String) async throws -> CallTicket {
        do {
            return try await ticket(for: callID)
        } catch {
            await endCall(callID: callID)
            throw error
        }
    }

    /// Asks getCallToken for this call's LiveKit token. The Worker checks the Firebase sign-in and
    /// reads the call with it, so the rules decide; it only answers once the call is accepted.
    private func ticket(for callID: String) async throws -> CallTicket {
        guard let tokenURL else { throw CallSignalingError.notConfigured }
        let idToken = try await auth.idToken()
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["callId": callID])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error where Self.isOffline(error) {
            throw CallSignalingError.offline
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(WorkerError.self, from: data))?.error
            throw CallSignalingError.tokenRefused(message ?? "Couldn't get a call token. Try again.")
        }
        let body = try JSONDecoder().decode(WorkerTicket.self, from: data)
        guard let expiresAt = Self.parseDate(body.expiresAt) else {
            throw CallSignalingError.tokenRefused("The call token was malformed.")
        }
        return CallTicket(
            callID: body.callId, roomName: body.roomName, token: body.token,
            callerID: body.callerId, volunteerID: body.volunteerId, expiresAt: expiresAt
        )
    }

    private struct WorkerTicket: Decodable {
        let token: String
        let callId: String
        let roomName: String
        let callerId: String
        let volunteerId: String
        let expiresAt: String
    }

    private struct WorkerError: Decodable {
        let error: String
    }

    /// The Worker sends JavaScript's `toISOString()`, which has milliseconds.
    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

enum CallSignalingError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case signedOut
    /// Nobody is online, or everyone online is already in a call or being rung.
    case noVolunteers
    /// Volunteers were rung, but every one declined or didn't answer.
    case nobodyAnswered
    /// No internet connection.
    case offline
    /// The volunteer picked up before the caller's skip went through.
    case callAccepted
    /// Shown to a volunteer whose accept lost the race.
    case callTaken
    case tokenRefused(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Calls aren't configured. Set CALL_TOKEN_URL to the deployed token Worker."
        case .signedOut: "Sign in to make or answer calls."
        case .noVolunteers: "No volunteers are online right now."
        case .nobodyAnswered: "No volunteer could take the call right now."
        case .offline: "You're offline. Check your internet connection."
        case .callAccepted: "The volunteer already answered."
        case .callTaken: "This call was taken or ended."
        case .tokenRefused(let message): message
        }
    }
}

extension Volunteer {
    /// Can be rung now: reachable (Online and a recent heartbeat), not in a call, and not ringing.
    /// A ring older than 45 seconds counts as free, the same as in firestore.rules.
    func isFreeToRing(at now: Date = Date()) -> Bool {
        guard isReachable(at: now), !inCall else { return false }
        guard ringingCallID != nil, let since = ringingSince else { return true }
        return now.timeIntervalSince(since) > FirestoreCallSignaling.staleRingAfter
    }
}

/// Lets the stream's cleanup remove the Firestore listener. `remove()` is safe from any thread.
private final class CallListenerHandle: @unchecked Sendable {
    private let registration: any ListenerRegistration
    init(_ registration: any ListenerRegistration) { self.registration = registration }
    func remove() { registration.remove() }
}
