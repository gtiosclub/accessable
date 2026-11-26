import Foundation

/// Presence writes await Firestore and can otherwise overtake one another on the main actor.
/// In particular, an Offline request must run after an in-flight Online request.
@MainActor
final class PresenceWriteQueue {
    private var tail: Task<Void, Error>?

    func run(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tail
        let next = Task { @MainActor in
            // A failed write must not prevent the following Offline/sign-out cleanup.
            if let previous { _ = try? await previous.value }
            try await operation()
        }
        tail = next
        try await next.value
    }
}
