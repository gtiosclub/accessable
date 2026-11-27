import Foundation
import Testing
@testable import AccessAble

struct GeoAimingCoachTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func turnAhead(distance: Double = 30) -> TripState {
        TripState(
            phase: .active,
            nextManeuver: Maneuver(
                kind: .turnLeft, instruction: "Turn left",
                coordinate: GeoCoordinate(latitude: 33.77, longitude: -84.39)
            ),
            distanceToNextManeuver: distance,
            updatedAt: start
        )
    }

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

    @Test
    func promptsOnTurnAheadWhileNotLocked() {
        var coach = GeoAimingCoach()
        let event = coach.update(
            enabled: true, tripActive: true, geo: unlockedGeo(), trip: turnAhead(), now: start
        )
        #expect(event?.text == GeoAimingCoach.promptText)
        #expect(event?.dedupKey == GeoAimingCoach.dedupKey)
    }

    @Test
    func noPromptWhenLockedOn() {
        var coach = GeoAimingCoach()
        let event = coach.update(
            enabled: true, tripActive: true, geo: lockedGeo(), trip: turnAhead(), now: start
        )
        #expect(event == nil)
    }

    @Test
    func promptsWhenPointedTooLowEvenIfLocalized() {
        var coach = GeoAimingCoach()
        let geo = GeoTrackingUpdate(
            state: .localized, accuracy: .high, timestamp: start,
            stateReason: .devicePointedTooLow
        )
        let event = coach.update(
            enabled: true, tripActive: true, geo: geo, trip: turnAhead(), now: start
        )
        #expect(event?.text == GeoAimingCoach.promptText)
    }

    @Test
    func noSecondPromptWithinTwoMinutes() {
        var coach = GeoAimingCoach()
        #expect(coach.update(
            enabled: true, tripActive: true, geo: unlockedGeo(), trip: turnAhead(), now: start
        ) != nil)
        // leave the turn window, then enter again within the cooldown
        #expect(coach.update(
            enabled: true, tripActive: true, geo: unlockedGeo(),
            trip: turnAhead(distance: 80), now: start.addingTimeInterval(1)
        ) == nil)
        let again = coach.update(
            enabled: true, tripActive: true, geo: unlockedGeo(), trip: turnAhead(),
            now: start.addingTimeInterval(60)
        )
        #expect(again == nil)
    }

    @Test
    func promptsAgainAfterCooldown() {
        var coach = GeoAimingCoach()
        #expect(coach.update(
            enabled: true, tripActive: true, geo: unlockedGeo(), trip: turnAhead(), now: start
        ) != nil)
        _ = coach.update(
            enabled: true, tripActive: true, geo: unlockedGeo(),
            trip: turnAhead(distance: 80), now: start.addingTimeInterval(1)
        )
        let again = coach.update(
            enabled: true, tripActive: true, geo: unlockedGeo(), trip: turnAhead(),
            now: start.addingTimeInterval(GeoAimingCoach.cooldown)
        )
        #expect(again?.text == GeoAimingCoach.promptText)
    }

    @Test
    func offRouteTriggersPrompt() {
        var coach = GeoAimingCoach()
        let event = coach.update(
            enabled: true, tripActive: true, geo: unlockedGeo(), trip: offRoute(), now: start
        )
        #expect(event?.text == GeoAimingCoach.promptText)
    }

    @Test
    func settingOffMeansSilence() {
        var coach = GeoAimingCoach()
        let event = coach.update(
            enabled: false, tripActive: true, geo: unlockedGeo(), trip: turnAhead(), now: start
        )
        #expect(event == nil)
    }
}
