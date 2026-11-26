import Foundation

/// Live configuration failures are explicit; they must never simulate a successful call.
struct UnavailableCallServices: VolunteerDirectory, PresenceService, CallSignaling, IncomingCallProviding {
    let message: String
    private var error: CallConfigurationError { CallConfigurationError(message: message) }

    func allVolunteers() -> AsyncStream<[Volunteer]> { AsyncStream { $0.yield([]); $0.finish() } }
    func onlineVolunteers() -> AsyncStream<[Volunteer]> { allVolunteers() }
    func onlineStates() -> AsyncStream<Bool> { AsyncStream { $0.yield(false); $0.finish() } }
    func setOnline(_ isOnline: Bool) async throws { throw error }
    @MainActor func incomingCalls(volunteerID: String) -> AsyncThrowingStream<IncomingCall?, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
    func requestCall(preferring volunteerID: String?, progress: @Sendable (CallRequestProgress) -> Void) async throws -> CallTicket { throw error }
    func accept(callID: String) async throws -> CallTicket { throw error }
    func decline(callID: String) async throws { throw error }
    func skip(callID: String) async throws { throw error }
    func endCall(callID: String) async {}
}

struct CallConfigurationError: LocalizedError, Equatable, Sendable {
    let message: String
    var errorDescription: String? { message }
}
