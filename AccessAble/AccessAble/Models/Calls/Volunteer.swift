import Foundation

/// A sighted volunteer who can take a call. Shared by the Call Help screens (sample content today)
/// and the calling backend (MATCH-x).
struct Volunteer: Identifiable, Hashable, Sendable {
    /// How old `lastSeen` may be before callers skip this volunteer. Matches the heartbeat rule in
    /// Docs/Calls/Overview.md: iOS suspends the app a few seconds after it leaves the screen, which
    /// stops the heartbeat.
    static let staleAfter: TimeInterval = 90

    let id: String
    var name: String
    var availableUntil: String
    /// The volunteer's Online toggle.
    var isOnline: Bool
    /// Last heartbeat. Defaults to now so sample content never looks stale.
    var lastSeen: Date = Date()
    var languages: [String] = []
    var bio: String = ""
    var inCall: Bool = false
    var ringingCallID: String? = nil
    var ringingSince: Date? = nil

    /// Online toggle on AND a recent heartbeat. Callers use this, not `isOnline` alone.
    func isReachable(at now: Date = Date()) -> Bool {
        isOnline && now.timeIntervalSince(lastSeen) < Self.staleAfter
    }
}
