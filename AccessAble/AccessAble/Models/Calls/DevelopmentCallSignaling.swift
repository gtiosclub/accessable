#if DEBUG
import Foundation
import LiveKit

/// Debug only: call tickets from LiveKit's development token server, so two phones can test a call
/// before VOLUNTEER-6's Worker exists. Joins the same room as the media test, so a phone running
/// Developer Tools' LiveKit media test as "Volunteer" picks up.
struct DevelopmentCallSignaling: CallSignaling {
    static let roomName = "accessable-call-test"   // same room as LiveKitMediaTestModel
    let serverID: String
    let auth: any AuthService

    func incomingCalls() -> AsyncStream<CallTicket> { AsyncStream { $0.finish() } }

    func startCall(to volunteerID: String) async throws -> CallTicket {
        let me = await auth.currentUser()?.id ?? "caller-\(UUID().uuidString.lowercased())"
        let credentials = try await DevelopmentTokenSource(id: serverID).fetch(TokenRequestOptions(
            roomName: Self.roomName, participantName: "Caller", participantIdentity: me
        ))
        return CallTicket(
            callID: UUID().uuidString, roomName: Self.roomName, token: credentials.participantToken,
            callerID: me, volunteerID: volunteerID, expiresAt: Date().addingTimeInterval(10 * 60)
        )
    }

    func accept(_ ticket: CallTicket) async throws {}
    func decline(_ ticket: CallTicket) async throws {}
    func end(_ ticket: CallTicket) async {}
}
#endif
