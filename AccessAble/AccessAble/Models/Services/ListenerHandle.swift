import FirebaseFirestore

/// Lets a stream's termination handler remove its Firestore listener from any thread.
final class ListenerHandle: @unchecked Sendable {
    private let registration: any ListenerRegistration
    init(_ registration: any ListenerRegistration) { self.registration = registration }
    func remove() { registration.remove() }
}
