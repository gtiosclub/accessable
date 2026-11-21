import Foundation

/// Where a call is, as the UI sees it. Published by `VideoCallSession.states()`.
enum CallState: Hashable, Sendable {
    case idle
    /// Ticket requested or sent; waiting for the volunteer to pick up.
    case ringing
    /// Joining the LiveKit room.
    case connecting
    case connected
    case ended(EndReason)
    case failed(String)

    enum EndReason: String, Hashable, Sendable {
        case hungUp
        case declined
        case unanswered
        case remoteLeft
    }

    var isActive: Bool {
        switch self {
        case .ringing, .connecting, .connected: true
        case .idle, .ended, .failed: false
        }
    }
}
