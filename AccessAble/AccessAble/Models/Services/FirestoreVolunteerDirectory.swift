import FirebaseFirestore
import Foundation
import os


struct FirestoreVolunteerDirectory: VolunteerDirectory {

    static let recheckInterval: Duration = .seconds(15)

    func allVolunteers() -> AsyncStream<[Volunteer]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let latest = OSAllocatedUnfairLock<[Volunteer]>(initialState: [])


            let registration = Firestore.firestore().collection("volunteers")
                .order(by: "lastSeen", descending: true)
                .limit(to: 100)
                .addSnapshotListener { snapshot, _ in
                    guard let snapshot else { return }
                    
                    let list = snapshot.documents.compactMap {
                        Volunteer(id: $0.documentID, firestoreData: $0.data(with: .estimate))
                    }
                    latest.withLock { $0 = list }
                    continuation.yield(list.sortedForDirectory())
                }
            let listener = ListenerHandle(registration)


            let recheck = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.recheckInterval)
                    continuation.yield(latest.withLock { $0 }.sortedForDirectory())
                }
            }

            continuation.onTermination = { _ in
                listener.remove()
                recheck.cancel()
            }
        }
    }

    func onlineVolunteers() -> AsyncStream<[Volunteer]> {
        let all = allVolunteers()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                for await list in all {
                    continuation.yield(list.filter { $0.isReachable() })
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension Volunteer {
    init?(id: String, firestoreData data: [String: Any]) {
        guard let name = data["displayName"] as? String,
              let isOnline = data["isOnline"] as? Bool,
              let lastSeen = (data["lastSeen"] as? Timestamp)?.dateValue() else { return nil }
        self.init(
            id: id, name: name, availableUntil: "", isOnline: isOnline, lastSeen: lastSeen,
            languages: data["languages"] as? [String] ?? [],
            bio: data["bio"] as? String ?? "",
            inCall: data["inCall"] as? Bool ?? false,
            ringingCallID: data["ringingCallId"] as? String,
            ringingSince: (data["ringingSince"] as? Timestamp)?.dateValue()
        )
    }
}


private final class ListenerHandle: @unchecked Sendable {
    private let registration: any ListenerRegistration
    init(_ registration: any ListenerRegistration) { self.registration = registration }
    func remove() { registration.remove() }
}
