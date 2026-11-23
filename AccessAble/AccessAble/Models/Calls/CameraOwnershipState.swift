import Foundation

/// Main-actor callers serialize access. AR clients keep their holds while a call owns the camera.
struct CameraOwnershipState: Sendable {
    private(set) var arRequested = false
    private(set) var callOwner: UUID?

    mutating func requestARStart() -> Bool {
        arRequested = true
        return callOwner == nil
    }

    mutating func requestARStop() { arRequested = false }

    mutating func acquireForCall() throws -> UUID {
        guard callOwner == nil else { throw CameraOwnershipError.alreadyInCall }
        let token = UUID()
        callOwner = token
        return token
    }

    /// Nil for a stale token; otherwise whether AR still has a client and should restart.
    mutating func releaseFromCall(_ token: UUID) -> Bool? {
        guard callOwner == token else { return nil }
        callOwner = nil
        return arRequested
    }
}

enum CameraOwnershipError: Error, Equatable, Sendable { case alreadyInCall }
