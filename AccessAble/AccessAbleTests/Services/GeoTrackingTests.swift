import ARKit
import Foundation
import Synchronization
import Testing
@testable import AccessAble

/// A camera at the origin turned `yaw` degrees counterclockwise seen from above, then tilted `pitch` degrees up.
private func camera(yaw: Float, pitch: Float = 0) -> simd_float4x4 {
    let turn = simd_quatf(angle: yaw * .pi / 180, axis: SIMD3(0, 1, 0))
    let tilt = simd_quatf(angle: pitch * .pi / 180, axis: SIMD3(1, 0, 0))
    return simd_float4x4(turn * tilt)
}

/// Keeps ARKit's callback, so the test answers when it likes, or never.
private final class HeldAvailabilityCheck: Sendable {
    private let completion = Mutex<(@Sendable (Bool, (any Error)?) -> Void)?>(nil)

    func check(_ completion: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        self.completion.withLock { $0 = completion }
    }

    func answer(_ available: Bool) {
        completion.withLock { $0 }?(available, nil)
    }
}

private struct NoImageryHere: Error {}

struct GeoTrackingTests {
    @Test
    func geoTrackingOnlyWhenWantedAndTheMeshIsNot() {
        #expect(SessionTracking.choose(geoWanted: true, meshWanted: false, meshSupported: true) == .geo)
        #expect(SessionTracking.choose(geoWanted: true, meshWanted: true, meshSupported: true) == .world)
        #expect(SessionTracking.choose(geoWanted: false, meshWanted: false, meshSupported: true) == .world)
    }

    @Test
    func aDeviceWithoutTheMeshKeepsGeoTracking() {
        #expect(SessionTracking.choose(geoWanted: true, meshWanted: true, meshSupported: false) == .geo)
        #expect(SessionTracking.choose(geoWanted: false, meshWanted: true, meshSupported: false) == .world)
    }

    @Test
    func listenersHearWhenGeoTrackingEnds() {
        #expect(SessionTracking.endsGeoTracking(from: .geo, to: nil))
        #expect(SessionTracking.endsGeoTracking(from: .geo, to: .world))
        #expect(!SessionTracking.endsGeoTracking(from: .geo, to: .geo))
        #expect(!SessionTracking.endsGeoTracking(from: .world, to: nil))
        #expect(!SessionTracking.endsGeoTracking(from: nil, to: .world))
    }

    @Test
    func updatesAreStampedWithTheFrameTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let captured = GeoTrackingUpdate.date(ofFrameTimestamp: 98.5, uptime: 100, now: now)

        #expect(captured == now.addingTimeInterval(-1.5))
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func geoFixesFromAnEndedSessionAreDropped() async {
        let manager = ARSessionManager()
        let updates = manager.geoTrackingUpdates()
        let fix = GeoTrackingUpdate(state: .localized, accuracy: .high, timestamp: .now)
        let ended = manager.sessionGeneration
        manager.stop()

        manager.deliverGeoLocation(
            fix, coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 1), altitude: 1, error: nil,
            fromSession: ended
        )
        manager.deliverGeoLocation(
            fix, coordinate: CLLocationCoordinate2D(latitude: 2, longitude: 2), altitude: 2, error: NoImageryHere(),
            fromSession: manager.sessionGeneration
        )
        manager.deliverGeoLocation(
            fix, coordinate: CLLocationCoordinate2D(latitude: 3, longitude: 3), altitude: 3, error: nil,
            fromSession: manager.sessionGeneration
        )

        for await update in updates {
            #expect(update.coordinate?.latitude == 3)
            break
        }
    }

    @Test
    func onlyFramesFromTheCurrentGeoRunCount() {
        var session = GeoSession()
        #expect(!session.accepts(frameTimestamp: 5))

        session.begin(.geo, at: 10)
        #expect(session.accepts(frameTimestamp: 10) && session.accepts(frameTimestamp: 11))
        // queued before the run started
        #expect(!session.accepts(frameTimestamp: 9.9))

        let geoRun = session.generation
        session.begin(.geo, at: 20)
        #expect(session.generation != geoRun)
        #expect(!session.accepts(frameTimestamp: 15))

        session.begin(.world, at: 30)
        #expect(!session.accepts(frameTimestamp: 31))
        session.begin(nil, at: 40)
        #expect(!session.accepts(frameTimestamp: 41))
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func framesAfterTheSessionStoppedPublishNothing() async {
        let manager = ARSessionManager()
        let updates = manager.geoTrackingUpdates()
        manager.stop()
        let located = Mutex(false)

        let localized = GeoTrackingUpdate(state: .localized, accuracy: .high, timestamp: .now)
        manager.publishGeoUpdate(localized, frameTimestamp: .greatestFiniteMagnitude, cameraTransform: matrix_identity_float4x4) { _, _ in
            located.withLock { $0 = true }
        }
        let localizing = GeoTrackingUpdate(state: .localizing, accuracy: .low, timestamp: .now)
        manager.publishGeoUpdate(localizing, frameTimestamp: .greatestFiniteMagnitude, cameraTransform: matrix_identity_float4x4) { _, _ in }
        // the first thing listeners hear is this, not the frames above
        manager.deliverGeoLocation(
            localized, coordinate: CLLocationCoordinate2D(latitude: 3, longitude: 3), altitude: 3, error: nil,
            fromSession: manager.sessionGeneration
        )

        #expect(!located.withLock { $0 })
        for await update in updates {
            #expect(update.coordinate?.latitude == 3)
            break
        }
    }

    // turning left (counterclockwise) from north faces west
    @Test(arguments: [(0 as Float, 0.0), (-90, 90), (180, 180), (90, 270), (-30, 30)])
    func headingIsWhereTheCameraFaces(yaw: Float, heading: Double) throws {
        let measured = try #require(GeoTrackingUpdate.heading(cameraTransform: camera(yaw: yaw)))

        #expect(abs(measured - heading) < 0.01 || abs(measured - heading) > 359.99)
    }

    @Test
    func tiltingKeepsTheHeadingUntilNearlyVertical() throws {
        let tilted = try #require(GeoTrackingUpdate.heading(cameraTransform: camera(yaw: -90, pitch: -60)))

        #expect(abs(tilted - 90) < 0.01)
        #expect(GeoTrackingUpdate.heading(cameraTransform: camera(yaw: -90, pitch: -80)) == nil)
        #expect(GeoTrackingUpdate.heading(cameraTransform: camera(yaw: -90, pitch: 85)) == nil)
    }

    @Test
    func arKitStatusIsMapped() {
        #expect(GeoTrackingUpdate.State(.localized) == .localized)
        #expect(GeoTrackingUpdate.State(.localizing) == .localizing)
        #expect(GeoTrackingUpdate.State(.notAvailable) == .notAvailable)
        #expect(GeoTrackingUpdate.Accuracy(.high) == .high)
        #expect(GeoTrackingUpdate.Accuracy(.undetermined) == .undetermined)
        #expect(GeoTrackingUpdate.Accuracy.low < .medium && GeoTrackingUpdate.Accuracy.medium < .high)
        #expect(GeoTrackingUpdate.StateReason(.none) == nil)
        #expect(GeoTrackingUpdate.StateReason(.devicePointedTooLow) == .devicePointedTooLow)
        #expect(GeoTrackingUpdate.StateReason(.waitingForLocation) == .waitingForLocation)
    }

    @Test
    func unavailableWhenARKitSaysSo() async {
        let available = await ARSessionManager.isGeoTrackingAvailableHere(check: { $0(false, NoImageryHere()) })
        #expect(available == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func anUnansweredCheckGivesUpExactlyAtTheCap() async throws {
        let clock = ManualClock()
        let held = HeldAvailabilityCheck()
        let available = Task {
            await ARSessionManager.isGeoTrackingAvailableHere(timeout: .seconds(3), clock: clock, check: held.check)
        }
        try await clock.waitForSleepers(1)

        clock.advance(by: .milliseconds(2999))
        // still waiting just short of the cap
        try await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(1))

        #expect(await available.value == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func anAnswerBeforeTheCapWins() async throws {
        let clock = ManualClock()
        let held = HeldAvailabilityCheck()
        let available = Task {
            await ARSessionManager.isGeoTrackingAvailableHere(timeout: .seconds(3), clock: clock, check: held.check)
        }
        try await clock.waitForSleepers(1)

        held.answer(true)

        #expect(await available.value == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func anAnswerAfterTheCapIsDropped() async throws {
        let clock = ManualClock()
        let held = HeldAvailabilityCheck()
        let available = Task {
            await ARSessionManager.isGeoTrackingAvailableHere(timeout: .seconds(3), clock: clock, check: held.check)
        }
        try await clock.waitForSleepers(1)
        clock.advance(by: .seconds(3))
        #expect(await available.value == false)

        // resuming the continuation a second time would trap
        held.answer(true)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheCheckGivesNo() async throws {
        let clock = ManualClock()
        let held = HeldAvailabilityCheck()
        let available = Task {
            await ARSessionManager.isGeoTrackingAvailableHere(timeout: .seconds(3), clock: clock, check: held.check)
        }
        try await clock.waitForSleepers(1)

        available.cancel()

        #expect(await available.value == false)
        held.answer(true)
    }
}
