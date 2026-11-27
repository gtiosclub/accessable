import Foundation
import Testing
@testable import AccessAble

struct GeoAimingCoachTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func ahead(_ kind: ManeuverKind = .turnLeft, distance: Double = 30) -> TripState {
        TripState(
            phase: .active,
            nextManeuver: Maneuver(
                kind: kind, instruction: "Turn left",
                coordinate: GeoCoordinate(latitude: 33.77, longitude: -84.39)
            ),
            distanceToNextManeuver: distance,
            updatedAt: start
        )
    }

    private func walking() -> TripState { ahead(distance: 120) }

    private func offRoute() -> TripState {
        TripState(phase: .active, isOffRoute: true, updatedAt: start)
    }

    private func lockedGeo() -> GeoTrackingUpdate {
        GeoTrackingUpdate(
            state: .localized, accuracy: .high, timestamp: start, stateReason: nil
        )
    }

    private func unlockedGeo(reason: GeoTrackingUpdate.StateReason? = .visualLocalizationFailed)
        -> GeoTrackingUpdate {
        GeoTrackingUpdate(
            state: .localizing, accuracy: .undetermined, timestamp: start, stateReason: reason
        )
    }

    /// The trip update that brings the turn, then the next one, `after` seconds from `start`.
    private func reachTurn(_ coach: inout GeoAimingCoach, geo: GeoTrackingUpdate?, after: TimeInterval = 0,
                           enabled: Bool = true) -> AnnouncementEvent? {
        let now = start.addingTimeInterval(after)
        _ = coach.update(enabled: enabled, geo: geo, trip: walking(), now: now)
        #expect(coach.update(enabled: enabled, geo: geo, trip: ahead(), now: now) == nil)
        return coach.update(enabled: enabled, geo: geo, trip: ahead(), now: now.addingTimeInterval(1))
    }

    @Test
    func promptsOnTurnAheadWhileNotLocked() {
        var coach = GeoAimingCoach()
        let event = reachTurn(&coach, geo: unlockedGeo())
        #expect(event?.text == GeoAimingCoach.promptText)
        #expect(event?.dedupKey == GeoAimingCoach.dedupKey)
    }

    // the trip says the turn cue after publishing the update that brought it, so the prompt waits for the next update
    @Test
    func neverOnTheUpdateThatBringsTheTurn() {
        var coach = GeoAimingCoach()
        #expect(coach.update(enabled: true, geo: unlockedGeo(), trip: ahead(), now: start) == nil)
        #expect(coach.update(enabled: true, geo: unlockedGeo(), trip: ahead(), now: start) != nil)
    }

    // normal, so it queues behind the turn cue instead of going ahead of it
    @Test
    func theCueComesFirst() {
        var coach = GeoAimingCoach()
        #expect(reachTurn(&coach, geo: unlockedGeo())?.priority == .normal)
    }

    @Test
    func noPromptWhenLockedOn() {
        var coach = GeoAimingCoach()
        #expect(reachTurn(&coach, geo: lockedGeo()) == nil)
    }

    @Test
    func noUpdateYetMeansNoPrompt() {
        var coach = GeoAimingCoach()
        #expect(reachTurn(&coach, geo: nil) == nil)
    }

    @Test
    func promptsWhenPointedTooLowEvenIfLocalized() {
        var coach = GeoAimingCoach()
        let geo = GeoTrackingUpdate(
            state: .localized, accuracy: .high, timestamp: start,
            stateReason: .devicePointedTooLow
        )
        #expect(reachTurn(&coach, geo: geo)?.text == GeoAimingCoach.promptText)
    }

    @Test
    func aLockLostBeforeTheTurnPrompts() {
        var coach = GeoAimingCoach()
        #expect(reachTurn(&coach, geo: lockedGeo()) == nil)
        let lost = coach.update(enabled: true, geo: unlockedGeo(), trip: ahead(distance: 15),
                                now: start.addingTimeInterval(10))
        #expect(lost?.text == GeoAimingCoach.promptText)
    }

    @Test
    func aLockLostJustAfterTheTurnPrompts() {
        var coach = GeoAimingCoach()
        #expect(reachTurn(&coach, geo: lockedGeo()) == nil)
        let lost = coach.update(enabled: true, geo: unlockedGeo(), trip: walking(),
                                now: start.addingTimeInterval(GeoAimingCoach.attentionWindow - 1))
        #expect(lost?.text == GeoAimingCoach.promptText)
    }

    @Test
    func aLockLostLongAfterTheTurnIsLeftAlone() {
        var coach = GeoAimingCoach()
        #expect(reachTurn(&coach, geo: lockedGeo()) == nil)
        let lost = coach.update(enabled: true, geo: unlockedGeo(), trip: walking(),
                                now: start.addingTimeInterval(GeoAimingCoach.attentionWindow))
        #expect(lost == nil)
    }

    @Test(arguments: [ManeuverKind.stairs, .elevator, .escalator, .enterBuilding, .exitBuilding, .cross, .arrive])
    func onlyTurnsCount(kind: ManeuverKind) {
        var coach = GeoAimingCoach()
        _ = coach.update(enabled: true, geo: unlockedGeo(), trip: walking(), now: start)
        _ = coach.update(enabled: true, geo: unlockedGeo(), trip: ahead(kind), now: start)
        #expect(coach.update(enabled: true, geo: unlockedGeo(), trip: ahead(kind), now: start) == nil)
    }

    @Test
    func noSecondPromptWithinTwoMinutes() {
        var coach = GeoAimingCoach()
        #expect(reachTurn(&coach, geo: unlockedGeo()) != nil)
        #expect(reachTurn(&coach, geo: unlockedGeo(), after: GeoAimingCoach.cooldown - 1) == nil)
    }

    @Test
    func promptsAgainAfterCooldown() {
        var coach = GeoAimingCoach()
        #expect(reachTurn(&coach, geo: unlockedGeo()) != nil)
        #expect(reachTurn(&coach, geo: unlockedGeo(), after: GeoAimingCoach.cooldown)?.text
            == GeoAimingCoach.promptText)
    }

    @Test
    func offRouteTriggersPrompt() {
        var coach = GeoAimingCoach()
        #expect(coach.update(enabled: true, geo: unlockedGeo(), trip: offRoute(), now: start) == nil)
        let event = coach.update(enabled: true, geo: unlockedGeo(), trip: offRoute(),
                                 now: start.addingTimeInterval(30))
        #expect(event?.text == GeoAimingCoach.promptText)
    }

    @Test
    func offRouteSharesTheCooldown() {
        var coach = GeoAimingCoach()
        #expect(reachTurn(&coach, geo: unlockedGeo()) != nil)
        _ = coach.update(enabled: true, geo: unlockedGeo(), trip: offRoute(), now: start.addingTimeInterval(30))
        #expect(coach.update(enabled: true, geo: unlockedGeo(), trip: offRoute(),
                             now: start.addingTimeInterval(31)) == nil)
    }

    @Test
    func settingOffMeansSilence() {
        var coach = GeoAimingCoach()
        #expect(reachTurn(&coach, geo: unlockedGeo(), enabled: false) == nil)
    }

    // a pause between, with the turn still ahead on resuming, starts again from the turn
    @Test
    func tripEndedKeepsTheCooldown() {
        var coach = GeoAimingCoach()
        #expect(reachTurn(&coach, geo: unlockedGeo()) != nil)
        coach.tripEnded()
        #expect(coach.update(enabled: true, geo: unlockedGeo(), trip: ahead(), now: start.addingTimeInterval(5)) == nil)
        #expect(coach.update(enabled: true, geo: unlockedGeo(), trip: ahead(), now: start.addingTimeInterval(6)) == nil)
        coach.tripEnded()
        let later = start.addingTimeInterval(GeoAimingCoach.cooldown + 1)
        #expect(coach.update(enabled: true, geo: unlockedGeo(), trip: ahead(), now: later) == nil)
        #expect(coach.update(enabled: true, geo: unlockedGeo(), trip: ahead(), now: later) != nil)
    }
}
