import FirebaseFirestore
import Foundation
import OSLog

private let logger = Logger(subsystem: "AccessAble", category: "RoutePreferences")

enum RoutePreferencesSyncError: Error, LocalizedError, Sendable {
    case permissionDenied
    /// The server didn't answer in time. Firestore keeps a save and sends it once online.
    case timedOut

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "The account refused access to its route preferences."
        case .timedOut: "The account didn't answer in time."
        }
    }
}

/// Turns Firestore's permission error into a clear one, and logs the real cause.
private func mapped(_ error: Error) -> Error {
    logger.error("Route preferences request failed: \(error.localizedDescription, privacy: .public)")
    let nsError = error as NSError
    if nsError.domain == FirestoreErrorDomain,
       nsError.code == FirestoreErrorCode.permissionDenied.rawValue {
        return RoutePreferencesSyncError.permissionDenied
    }
    return error
}

/// Keeps route preferences at `users/{uid}/settings/routePreferences`, which only that user may read or write.
struct FirestoreRoutePreferencesStore: RoutePreferencesSyncing {
    /// How long a load or save waits for the server.
    static let timeout: Duration = .seconds(10)

    private let clock: any Clock<Duration>

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    private static func document(_ userID: String) -> DocumentReference {
        Firestore.firestore().collection("users").document(userID).collection("settings").document("routePreferences")
    }

    func load(userID: String) async throws -> RoutePreferences? {
        try await Self.answer(within: Self.timeout, clock: clock) { finish in
            Self.document(userID).getDocument { snapshot, error in
                finish(Result {
                    if let error { throw error }
                    guard let snapshot, snapshot.exists else { return nil }
                    return try snapshot.data(as: RoutePreferences.self)
                })
            }
        }
    }

    func save(_ preferences: RoutePreferences, userID: String) async throws {
        var values: [String: Any]
        do { values = try Firestore.Encoder().encode(preferences) } catch { throw mapped(error) }
        values["updatedAt"] = FieldValue.serverTimestamp()
        try await Self.answer(within: Self.timeout, clock: clock) { finish in
            Self.document(userID).setData(values) { error in
                finish(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    /// Starts a request and waits for its answer, at most `timeout`, then throws `.timedOut`. Firestore can't cancel
    /// a request, so an answer after the timeout is only logged if it failed.
    static func answer<Value: Sendable>(
        within timeout: Duration,
        clock: any Clock<Duration>,
        _ start: (_ finish: @escaping @Sendable (Result<Value, any Error>) -> Void) -> Void
    ) async throws -> Value {
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                let outcome = FirstOutcome<Value>()
                outcome.wait(continuation)
                // Not structured: nothing should wait on the request once the timeout passes.
                outcome.cancelsOnFinish(Task {
                    do { try await clock.sleep(for: timeout) } catch { return }
                    outcome.finish(.failure(RoutePreferencesSyncError.timedOut))
                })
                start { result in
                    guard !outcome.finish(result), case .failure(let error) = result else { return }
                    logger.error("Late route preferences request failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            throw mapped(error)
        }
    }
}
