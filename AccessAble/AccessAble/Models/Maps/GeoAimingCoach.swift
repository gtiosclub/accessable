import Foundation

/// Decides when to ask the user to hold the phone up so geo-tracking can lock on (AR-5).
///
/// A turn coming up or going off route draws attention to the position: while the turn is ahead, while off route, and
/// for `attentionWindow` after either begins, geo not locked on (or ARKit saying the phone is pointed too low) brings
/// the prompt. Never on the trip update that began it: the trip says that update's turn or off-route cue after
/// publishing it, and the prompt comes after the cue. At most once every two minutes.
struct GeoAimingCoach: Equatable, Sendable {
    static let promptText = "For a more precise position, hold your phone up facing forward."
    static let dedupKey = "geo-aiming-hold-up"
    static let cooldown: TimeInterval = 120
    /// How long after a turn comes up or the user goes off route a lost lock still brings the prompt.
    static let attentionWindow: TimeInterval = 20

    private var lastPromptAt: Date?
    private var wasNearTurn = false
    private var wasOffRoute = false
    private var attentionUntil: Date?

    /// Forgets the turn or off-route in hand when the trip isn't being walked; keeps the cooldown clock.
    mutating func tripEnded() {
        wasNearTurn = false
        wasOffRoute = false
        attentionUntil = nil
    }

    /// Returns a prompt event when one is due on this trip update; nil otherwise.
    /// - Parameter geo: The latest geo-tracking update; nil before the first, which never prompts.
    mutating func update(enabled: Bool, geo: GeoTrackingUpdate?, trip: TripState, now: Date) -> AnnouncementEvent? {
        guard enabled else {
            tripEnded()
            return nil
        }

        let nearTurn = Self.isNearTurn(trip)
        let offRoute = trip.isOffRoute
        let began = (nearTurn && !wasNearTurn) || (offRoute && !wasOffRoute)
        wasNearTurn = nearTurn
        wasOffRoute = offRoute
        if began {
            attentionUntil = now.addingTimeInterval(Self.attentionWindow)
            return nil
        }

        let attentive = nearTurn || offRoute || attentionUntil.map { now < $0 } == true
        guard attentive, let geo, Self.needsAim(geo) else { return nil }
        if let last = lastPromptAt, now.timeIntervalSince(last) < Self.cooldown { return nil }
        lastPromptAt = now
        return AnnouncementEvent(
            category: .system,
            priority: .normal,
            text: Self.promptText,
            source: .system,
            dedupKey: Self.dedupKey
        )
    }

    static func needsAim(_ geo: GeoTrackingUpdate) -> Bool {
        let lockedOn = geo.state == .localized && geo.accuracy >= .medium
        return !lockedOn || geo.stateReason == .devicePointedTooLow
    }

    /// A turn within the distance its `.prepare` falls due. Stairs, lifts and building doors are left out: they are
    /// at or inside buildings, where geo-tracking doesn't help; crossings aren't a change of direction.
    static func isNearTurn(_ trip: TripState) -> Bool {
        guard let distance = trip.distanceToNextManeuver, distance <= RouteProgressTracker.prepareDistance,
              let kind = trip.nextManeuver?.kind else { return false }
        switch kind {
        case .turnLeft, .turnRight, .slightLeft, .slightRight, .uTurn:
            return true
        case .depart, .straight, .cross, .arrive, .stairs, .elevator, .escalator, .enterBuilding, .exitBuilding:
            return false
        }
    }
}
