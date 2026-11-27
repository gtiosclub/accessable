import Foundation

/// Decides when to ask the user to hold the phone up so geo-tracking can lock on (AR-5).
///
/// Prompt once when a turn is coming up or the user goes off route, while geo isn't locked on
/// (or ARKit says the phone is pointed too low). At most once every two minutes.
struct GeoAimingCoach: Equatable, Sendable {
    static let promptText = "For a more precise position, hold your phone up facing forward."
    static let dedupKey = "geo-aiming-hold-up"
    static let cooldown: TimeInterval = 120
    /// Matches `RouteProgressTracker.prepareDistance`.
    static let prepareDistance: Double = 40

    private var lastPromptAt: Date?
    private var wasNearTurn = false
    private var wasOffRoute = false

    /// Clears the rising-edge memory for a new trip; keeps the cooldown clock.
    mutating func tripEnded() {
        wasNearTurn = false
        wasOffRoute = false
    }

    /// Returns a prompt event when one is due; nil otherwise.
    mutating func update(
        enabled: Bool,
        tripActive: Bool,
        geo: GeoTrackingUpdate?,
        trip: TripState,
        now: Date
    ) -> AnnouncementEvent? {
        guard enabled, tripActive else {
            wasNearTurn = false
            wasOffRoute = false
            return nil
        }

        let lockedOn = Self.isLockedOn(geo)
        let pointedTooLow = geo?.stateReason == .devicePointedTooLow
        let needsAim = !lockedOn || pointedTooLow

        let nearTurn = Self.isNearTurn(trip)
        let offRoute = trip.isOffRoute
        let turnEdge = nearTurn && !wasNearTurn
        let offRouteEdge = offRoute && !wasOffRoute
        wasNearTurn = nearTurn
        wasOffRoute = offRoute

        guard needsAim, turnEdge || offRouteEdge else { return nil }
        if let last = lastPromptAt, now.timeIntervalSince(last) < Self.cooldown { return nil }
        lastPromptAt = now
        return AnnouncementEvent(
            category: .system,
            priority: .high,
            text: Self.promptText,
            source: .system,
            dedupKey: Self.dedupKey
        )
    }

    static func isLockedOn(_ geo: GeoTrackingUpdate?) -> Bool {
        guard let geo else { return false }
        return geo.state == .localized && geo.accuracy >= .medium
    }

    static func isNearTurn(_ trip: TripState) -> Bool {
        guard let distance = trip.distanceToNextManeuver, distance <= prepareDistance,
              let kind = trip.nextManeuver?.kind else { return false }
        switch kind {
        case .turnLeft, .turnRight, .slightLeft, .slightRight, .uTurn, .cross,
             .stairs, .elevator, .escalator, .enterBuilding, .exitBuilding:
            return true
        case .depart, .straight, .arrive:
            return false
        }
    }
}
