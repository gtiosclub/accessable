import FirebaseFirestore
import Foundation
import os

/// Owner: Calls (SAVE-1). Saves live at `saves/<saverId>_<savedId>`; firebase/firestore.rules
/// check both names and that the two people have different roles (tests in
/// firebase/tests/saves-history.test.js).
struct FirestoreSavesService: SavesService {
    static let limit = 200
    let auth: any AuthService

    func savedPeople() -> AsyncThrowingStream<[SavedPerson], Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let listener = OSAllocatedUnfairLock<ListenerHandle?>(initialState: nil)
            let task = Task {
                guard let me = await auth.currentUser()?.id else {
                    continuation.finish(throwing: CallHelpError.signedOut)
                    return
                }
                let db = Firestore.firestore()
                let registration = db.collection("saves")
                    .whereField("saverId", isEqualTo: me)
                    .limit(to: Self.limit)
                    .addSnapshotListener { snapshot, error in
                        if let error { continuation.finish(throwing: error); return }
                        guard let snapshot else { return }
                        let people = snapshot.documents.compactMap { document -> SavedPerson? in
                            let data = document.data()
                            guard let id = data["savedId"] as? String, let name = data["savedName"] as? String else { return nil }
                            return SavedPerson(id: id, name: name, isMutual: false)
                        }
                        continuation.yield(people.sortedByName())
                        // Whether each starred back is a point read per person, which the rules allow.
                        Task { continuation.yield(await Self.markMutual(people, me: me)) }
                    }
                let handle = ListenerHandle(registration)
                listener.withLock { $0 = handle }
                if Task.isCancelled { handle.remove() }
            }
            continuation.onTermination = { _ in
                task.cancel()
                listener.withLock { $0?.remove() }
            }
        }
    }

    private static func markMutual(_ people: [SavedPerson], me: String) async -> [SavedPerson] {
        var marked = people
        for index in marked.indices {
            let reverse = Firestore.firestore().collection("saves").document(PairID.make(marked[index].id, me))
            marked[index].isMutual = (try? await reverse.getDocument().exists) ?? false
        }
        return marked.sortedByName()
    }

    func setSaved(_ saved: Bool, personID: String) async throws {
        guard let me = await auth.currentUser()?.id else { throw CallHelpError.signedOut }
        let db = Firestore.firestore()
        let ref = db.collection("saves").document(PairID.make(me, personID))
        do {
            guard saved else {
                try await ref.delete()
                return
            }
            // Neither side may read the other's profile; the rules check the names against them.
            // A caller can read a volunteer's directory entry; a volunteer reads the caller's
            // name from their chat or call.
            let mine = try await db.collection("users").document(me).getDocument().data()
            guard let myName = (mine?["displayName"] as? String).map(IncomingCall.firstName(from:)) else {
                throw CallHelpError.unavailable
            }
            guard let theirName = try await firstName(of: personID, me: me, db: db) else {
                throw CallHelpError.unavailable
            }
            try await ref.setData([
                "saverId": me, "savedId": personID, "saverName": myName, "savedName": theirName,
                "createdAt": FieldValue.serverTimestamp(),
            ])
        } catch let error as CallHelpError {
            throw error
        } catch {
            throw CallHelpError.from(error)
        }
    }

    private func firstName(of personID: String, me: String, db: Firestore) async throws -> String? {
        if let volunteer = try? await db.collection("volunteers").document(personID).getDocument().data(),
           let name = volunteer["displayName"] as? String {
            return IncomingCall.firstName(from: name)
        }
        // A caller who starred this volunteer already sent their name.
        if let save = try? await db.collection("saves").document(PairID.make(personID, me)).getDocument().data(),
           let name = save["saverName"] as? String {
            return name
        }
        if let chat = try? await db.collection("chats").document(PairID.make(personID, me)).getDocument().data(),
           let name = chat["callerFirstName"] as? String {
            return name
        }
        return nil
    }
}

/// Owner: Calls (HISTORY-1). Answered calls from the `calls` collection; the rules let each side
/// list only their own.
struct FirestoreCallHistory: CallHistoryProviding {
    static let limit = 100

    let auth: any AuthService

    func pastCalls(as role: UserRole) async throws -> [PastCall] {
        guard let me = await auth.currentUser()?.id else { throw CallHelpError.signedOut }
        let field = role == .caller ? "callerId" : "volunteerId"
        do {
            // No orderBy, so no composite index is needed; sorted here instead.
            let snapshot = try await Firestore.firestore().collection("calls")
                .whereField(field, isEqualTo: me)
                .limit(to: Self.limit)
                .getDocuments()
            return snapshot.documents
                .compactMap { PastCall(id: $0.documentID, firestoreData: $0.data(), role: role) }
                .sorted { $0.startedAt > $1.startedAt }
        } catch {
            throw CallHelpError.from(error)
        }
    }
}

extension PastCall {
    /// Only calls that were answered and then ended; calls from before `acceptedAt` existed are left out.
    init?(id: String, firestoreData data: [String: Any], role: UserRole) {
        guard data["status"] as? String == "ended",
              let accepted = (data["acceptedAt"] as? Timestamp)?.dateValue(),
              let ended = (data["updatedAt"] as? Timestamp)?.dateValue(),
              let other = data[role == .caller ? "volunteerId" : "callerId"] as? String else { return nil }
        self.init(id: id, otherID: other,
                  otherName: role == .volunteer ? (data["callerFirstName"] as? String ?? "Caller") : nil,
                  startedAt: accepted, duration: max(0, ended.timeIntervalSince(accepted)))
    }
}

enum CallHelpError: Error, LocalizedError, Equatable, Sendable {
    case signedOut
    case notAllowed
    case offline
    case unavailable

    var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in to see your volunteers."
        case .notAllowed: "That couldn't be saved for this person."
        case .offline: "You're offline. Try again when you're connected."
        case .unavailable: "This isn't available right now. Please try again."
        }
    }

    static func from(_ error: Error) -> CallHelpError {
        let nsError = error as NSError
        if nsError.domain == FirestoreErrorDomain {
            if nsError.code == FirestoreErrorCode.permissionDenied.rawValue { return .notAllowed }
            if nsError.code == FirestoreErrorCode.unavailable.rawValue { return .offline }
        }
        if nsError.domain == NSURLErrorDomain { return .offline }
        return .unavailable
    }
}

extension Array where Element == SavedPerson {
    func sortedByName() -> [SavedPerson] {
        sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
