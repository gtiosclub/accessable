import FirebaseFirestore
import Foundation
import os

/// Owner: Calls (CHAT-1). Chats live at `chats/<callerId>_<volunteerId>`, messages in its
/// `messages` subcollection. firebase/firestore.rules enforce every write (tests in
/// firebase/tests/chats.test.js, whose helpers write what this file writes).
struct FirestoreChatService: ChatService {
    /// Older messages than this are left out of the screen.
    static let messageLimit = 200
    /// The most chats an inbox shows. Must not exceed the rules' list limit.
    static let chatLimit = 50

    let auth: any AuthService

    func currentUserID() async -> String? { await auth.currentUser()?.id }

    func messages(chatID: String) -> AsyncThrowingStream<[ChatMessage], Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let registration = Firestore.firestore().collection("chats").document(chatID)
                .collection("messages")
                .order(by: "sentAt")
                .limit(toLast: Self.messageLimit)
                .addSnapshotListener { snapshot, error in
                    if let error { continuation.finish(throwing: Self.chatError(error)); return }
                    guard let snapshot else { return }
                    continuation.yield(snapshot.documents.compactMap {
                        ChatMessage(id: $0.documentID, firestoreData: $0.data(with: .estimate))
                    })
                }
            let listener = ListenerHandle(registration)
            continuation.onTermination = { _ in listener.remove() }
        }
    }

    func send(_ text: String, chatID: String) async throws {
        guard let me = await auth.currentUser()?.id else { throw ChatError.signedOut }
        guard let text = ChatMessage.sendable(text) else { throw ChatError.invalidMessage }
        guard let parties = ChatID.parties(of: chatID), me == parties.caller || me == parties.volunteer else {
            throw ChatError.notAllowed
        }
        let db = Firestore.firestore()
        let chatRef = db.collection("chats").document(chatID)
        let messageRef = chatRef.collection("messages").document()
        do {
            _ = try await db.runTransaction { transaction, errorPointer -> Any? in
                do {
                    if try transaction.getDocument(chatRef).exists {
                        transaction.updateData(["updatedAt": FieldValue.serverTimestamp()], forDocument: chatRef)
                    } else {
                        // A caller starts a chat; a volunteer only once both have starred each other,
                        // which the rules check.
                        transaction.setData(
                            try newChat(parties: parties, startedBy: me, transaction: transaction, db: db),
                            forDocument: chatRef)
                    }
                    transaction.setData(
                        ["senderId": me, "text": text, "sentAt": FieldValue.serverTimestamp()],
                        forDocument: messageRef)
                    return nil
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
            }
        } catch {
            throw Self.chatError(error)
        }
    }

    /// Neither side may read the other's private users doc, so the chat carries both names.
    private func newChat(
        parties: (caller: String, volunteer: String), startedBy me: String, transaction: Transaction, db: Firestore
    ) throws -> [String: Any] {
        let volunteer = try transaction.getDocument(db.collection("volunteers").document(parties.volunteer)).data()
        guard let volunteerName = volunteer?["displayName"] as? String else { throw ChatError.volunteerUnavailable }
        var data: [String: Any] = [
            "callerId": parties.caller,
            "volunteerId": parties.volunteer,
            "volunteerName": volunteerName,
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp(),
        ]
        // Left out when the rules would refuse it; the volunteer then sees "Caller".
        if me == parties.caller {
            let profile = try transaction.getDocument(db.collection("users").document(parties.caller)).data()
            if let name = profile?["displayName"] as? String,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let first = IncomingCall.firstName(from: name)
                if first.unicodeScalars.count <= 80 { data["callerFirstName"] = first }
            }
        } else {
            // A volunteer can't read the caller's profile; the caller's star carries their first name.
            let save = try transaction.getDocument(
                db.collection("saves").document(PairID.make(parties.caller, parties.volunteer))).data()
            guard let name = save?["saverName"] as? String else { throw ChatError.notAllowed }
            data["callerFirstName"] = name
        }
        return data
    }

    func volunteerChats() -> AsyncThrowingStream<[ChatThread], Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let listener = OSAllocatedUnfairLock<ListenerHandle?>(initialState: nil)
            let task = Task {
                guard let me = await auth.currentUser()?.id else {
                    continuation.finish(throwing: ChatError.signedOut)
                    return
                }
                // No orderBy, so no composite index is needed; the inbox sorts itself.
                let registration = Firestore.firestore().collection("chats")
                    .whereField("volunteerId", isEqualTo: me)
                    .limit(to: Self.chatLimit)
                    .addSnapshotListener { snapshot, error in
                        if let error { continuation.finish(throwing: Self.chatError(error)); return }
                        guard let snapshot else { return }
                        let threads = snapshot.documents.compactMap {
                            ChatThread(id: $0.documentID, firestoreData: $0.data(with: .estimate))
                        }
                        continuation.yield(threads.sorted { $0.updatedAt > $1.updatedAt })
                    }
                let handle = ListenerHandle(registration)
                listener.withLock { $0 = handle }
                // Ended while the listener was being added.
                if Task.isCancelled { handle.remove() }
            }
            continuation.onTermination = { _ in
                task.cancel()
                listener.withLock { $0?.remove() }
            }
        }
    }

    private static func chatError(_ error: Error) -> Error {
        if let error = error as? ChatError { return error }
        let nsError = error as NSError
        if nsError.domain == FirestoreErrorDomain {
            switch nsError.code {
            case FirestoreErrorCode.permissionDenied.rawValue: return ChatError.notAllowed
            case FirestoreErrorCode.unavailable.rawValue: return ChatError.offline
            default: return ChatError.unavailable
            }
        }
        if nsError.domain == NSURLErrorDomain { return ChatError.offline }
        return ChatError.unavailable
    }
}

extension ChatMessage {
    init?(id: String, firestoreData data: [String: Any]) {
        guard let text = data["text"] as? String, let sender = data["senderId"] as? String else { return nil }
        self.init(id: id, text: text, senderID: sender,
                  sentAt: (data["sentAt"] as? Timestamp)?.dateValue() ?? Date())
    }
}

extension ChatThread {
    init?(id: String, firestoreData data: [String: Any]) {
        guard data["callerId"] is String else { return nil }
        self.init(id: id, callerFirstName: data["callerFirstName"] as? String ?? "Caller",
                  updatedAt: (data["updatedAt"] as? Timestamp)?.dateValue() ?? Date())
    }
}
