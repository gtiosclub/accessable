import Foundation

/// Everything one side needs to join a call. `getCallToken` (the Cloudflare Worker, MATCH-1) mints it;
/// the LiveKit API secret never reaches the app, only this short-lived token does.
struct CallTicket: Identifiable, Hashable, Sendable, Codable {
    var id: String { callID }

    let callID: String
    /// LiveKit room both sides join.
    let roomName: String
    /// Short-lived LiveKit access token (JWT) for this user and room.
    let token: String
    let callerID: String
    let volunteerID: String
    /// Callers and volunteers must give up on a ticket after this.
    let expiresAt: Date

    func isExpired(at now: Date = Date()) -> Bool { now >= expiresAt }
}
