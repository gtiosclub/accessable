import FirebaseFirestore
import Foundation
import UIKit


@MainActor
final class FirestorePresenceService: PresenceService {

    static let heartbeatInterval: Duration = .seconds(45)

    private nonisolated let states = Broadcaster<Bool>(replaysLatest: true)
    private let auth: any AuthService
    private let profiles: any UserProfileStore
    private var isOnline = false
    private var heartbeat: Task<Void, Never>?
    private var authWatcher: Task<Void, Never>?
    private var backgroundObserver: (any NSObjectProtocol)?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(auth: any AuthService, profiles: any UserProfileStore) {
        self.auth = auth
        self.profiles = profiles
        states.send(false)


        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.wentToBackground() }
        }


        authWatcher = Task { [weak self, auth] in
            for await user in auth.userChanges() where user == nil {
                self?.stopLocally()
            }
        }
    }



    nonisolated func onlineStates() -> AsyncStream<Bool> {
        states.stream()
    }

    nonisolated func setOnline(_ isOnline: Bool) async throws {
        try await update(isOnline: isOnline)
    }



    private func update(isOnline newValue: Bool) async throws {
        guard newValue != isOnline else { return }
        guard let user = await auth.currentUser() else { throw PresenceError.signedOut }

        if newValue {
            guard let profile = try await profiles.load(userID: user.id) else { throw PresenceError.noProfile }
            try await writeOnline(userID: user.id, profile: profile)
            isOnline = true
            states.send(true)
            startHeartbeat(userID: user.id)
        } else {
            stopLocally()
            try await writeOffline(userID: user.id)
        }
    }

    private func startHeartbeat(userID: String) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard !Task.isCancelled else { return }
                try? await self?.writeHeartbeat(userID: userID)
            }
        }
    }

    private func stopLocally() {
        heartbeat?.cancel()
        heartbeat = nil
        guard isOnline else { return }
        isOnline = false
        states.send(false)
    }

    private func wentToBackground() {
        guard isOnline else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        Task {
            try? await update(isOnline: false)
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }


    private nonisolated func document(_ userID: String) -> DocumentReference {
        Firestore.firestore().collection("volunteers").document(userID)
    }

    private nonisolated func writeOnline(userID: String, profile: UserProfile) async throws {
        var fields: [String: Any] = [
            "displayName": profile.displayName,
            "languages": profile.languages,
            "isOnline": true,
            "lastSeen": FieldValue.serverTimestamp(),
        ]
        do {
            try await document(userID).updateData(fields)
        } catch let error as NSError
            where error.domain == FirestoreErrorDomain && error.code == FirestoreErrorCode.notFound.rawValue {
            fields["bio"] = ""
            fields["inCall"] = false
            try await document(userID).setData(fields)
        }
    }

    private nonisolated func writeOffline(userID: String) async throws {
        do {
            try await document(userID).updateData([
                "isOnline": false, "lastSeen": FieldValue.serverTimestamp(),
            ])
        } catch let error as NSError
            where error.domain == FirestoreErrorDomain && error.code == FirestoreErrorCode.notFound.rawValue {
        }
    }

    private nonisolated func writeHeartbeat(userID: String) async throws {
        try await document(userID).updateData(["lastSeen": FieldValue.serverTimestamp()])
    }
}

enum PresenceError: Error, LocalizedError, Sendable {
    case signedOut
    case noProfile

    var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in to go online."
        case .noProfile: "Finish setting up your volunteer profile to go online."
        }
    }
}
