import FirebaseFirestore
import Foundation

/// Watches only the signed-in volunteer document and the single call it references.
struct FirestoreIncomingCalls: IncomingCallProviding {
    let presence: any PresenceService

    @MainActor func incomingCalls(volunteerID: String) -> AsyncThrowingStream<IncomingCall?, Error> {
        let pair = AsyncThrowingStream<IncomingCall?, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = IncomingCallPresenceSubscription(
            volunteerID: volunteerID, presence: presence, continuation: pair.continuation
        )
        pair.continuation.onTermination = { _ in
            Task { @MainActor in observer.stop() }
        }
        observer.start()
        return pair.stream
    }
}

/// Local toggle and server state must both allow ringing. A stale server-side Online flag
/// from a previous app launch must not ring a volunteer whose current toggle is off.
@MainActor
private final class IncomingCallPresenceSubscription {
    private let volunteerID: String
    private let presence: any PresenceService
    private let continuation: AsyncThrowingStream<IncomingCall?, Error>.Continuation
    private var presenceTask: Task<Void, Never>?
    private var observer: IncomingCallSubscription?
    private var online: Bool?
    private var stopped = false

    init(volunteerID: String, presence: any PresenceService,
         continuation: AsyncThrowingStream<IncomingCall?, Error>.Continuation) {
        self.volunteerID = volunteerID
        self.presence = presence
        self.continuation = continuation
    }

    func start() {
        presenceTask = Task { [weak self, presence] in
            for await value in presence.onlineStates() {
                guard !Task.isCancelled, let self, !stopped else { return }
                guard online != value else { continue }
                online = value
                observer?.stop()
                observer = nil
                continuation.yield(nil)
                if value {
                    let next = IncomingCallSubscription(volunteerID: volunteerID, continuation: continuation)
                    observer = next
                    next.start()
                }
            }
        }
    }

    func stop() {
        stopped = true
        presenceTask?.cancel()
        presenceTask = nil
        observer?.stop()
        observer = nil
    }
}

@MainActor
private final class IncomingCallSubscription {
    private let volunteerID: String
    private let continuation: AsyncThrowingStream<IncomingCall?, Error>.Continuation
    private var volunteerListener: (any ListenerRegistration)?
    private var callListener: (any ListenerRegistration)?
    private var callID: String?
    private var ringingSince: Date?
    private var stopped = false
    private var generation = UUID()

    init(volunteerID: String, continuation: AsyncThrowingStream<IncomingCall?, Error>.Continuation) {
        self.volunteerID = volunteerID
        self.continuation = continuation
    }

    func start() {
        volunteerListener = Firestore.firestore().collection("volunteers").document(volunteerID)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in self?.receiveVolunteer(snapshot, error: error) }
            }
    }

    func stop() {
        stopped = true
        generation = UUID()
        volunteerListener?.remove()
        volunteerListener = nil
        callListener?.remove()
        callListener = nil
    }

    private func receiveVolunteer(_ snapshot: DocumentSnapshot?, error: Error?) {
        guard !stopped else { return }
        if let error { continuation.finish(throwing: error); stop(); return }
        let data = snapshot?.data() ?? [:]
        guard data["isOnline"] as? Bool == true, data["inCall"] as? Bool != true,
              let id = data["ringingCallId"] as? String, !id.isEmpty, !id.contains("/"),
              data["ringingSince"] is Timestamp else {
            clearCall()
            return
        }
        guard id != callID else { return } // Heartbeats must not restart the timer or ring sound.
        clearCall()
        callID = id
        // Timed from when the ring reached this phone, not the server's `ringingSince`: a phone
        // clock that runs fast would otherwise make every ring look expired and drop it unheard.
        // The call listener still dismisses it as soon as the caller skips or hangs up.
        ringingSince = Date()
        let expected = generation
        callListener = Firestore.firestore().collection("calls").document(id)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in self?.receiveCall(snapshot, error: error, expected: expected) }
            }
    }

    private func clearCall() {
        generation = UUID()
        callListener?.remove()
        callListener = nil
        callID = nil
        ringingSince = nil
        continuation.yield(nil)
    }

    private func receiveCall(_ snapshot: DocumentSnapshot?, error: Error?, expected: UUID) {
        guard !stopped, generation == expected else { return }
        if let error { continuation.finish(throwing: error); stop(); return }
        guard let data = snapshot?.data(), data["status"] as? String == "ringing",
              data["volunteerId"] as? String == volunteerID,
              let caller = data["callerId"] as? String, caller != volunteerID,
              let id = callID, let since = ringingSince else {
            continuation.yield(nil)
            return
        }
        // Old call records have no name; do not try to read another user's private profile.
        let name = IncomingCall.firstName(from: data["callerFirstName"] as? String ?? "Caller")
        continuation.yield(IncomingCall(id: id, callerFirstName: name, ringingSince: since))
    }
}
