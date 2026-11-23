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
        #expect(SessionTracking.choose(geoWanted: true, meshWanted: false) == .geo)
        #expect(SessionTracking.choose(geoWanted: true, meshWanted: true) == .world)
        #expect(SessionTracking.choose(geoWanted: false, meshWanted: false) == .world)
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
