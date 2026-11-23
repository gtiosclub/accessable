import ARKit
import Foundation
import Testing
@testable import AccessAble

/// A camera at the origin turned `yaw` degrees counterclockwise seen from above, then tilted `pitch` degrees up.
private func camera(yaw: Float, pitch: Float = 0) -> simd_float4x4 {
    let turn = simd_quatf(angle: yaw * .pi / 180, axis: SIMD3(0, 1, 0))
    let tilt = simd_quatf(angle: pitch * .pi / 180, axis: SIMD3(1, 0, 0))
    return simd_float4x4(turn * tilt)
}

struct GeoTrackingTests {
    @Test
    func geoTrackingOnlyWhenWantedAndTheMeshIsNot() {
        #expect(SessionTracking.choose(geoWanted: true, geoAvailable: true, meshWanted: false) == .geo)
        #expect(SessionTracking.choose(geoWanted: true, geoAvailable: true, meshWanted: true) == .world)
        #expect(SessionTracking.choose(geoWanted: false, geoAvailable: true, meshWanted: false) == .world)
    }

    // the camera starts at once rather than wait for Apple's answer
    @Test
    func worldTrackingUntilAvailabilityIsKnown() {
        #expect(SessionTracking.choose(geoWanted: true, geoAvailable: nil, meshWanted: false) == .world)
        #expect(SessionTracking.choose(geoWanted: true, geoAvailable: false, meshWanted: false) == .world)
    }

    @Test
    func anAvailabilityAnswerIsKeptForAWalk() {
        let checked = Date(timeIntervalSince1970: 1_000_000)
        let answer = GeoAvailability(isAvailable: true, checkedAt: checked)

        #expect(answer.isFresh(at: checked.addingTimeInterval(5 * 60)))
        #expect(!answer.isFresh(at: checked.addingTimeInterval(GeoAvailability.lifetime + 1)))
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
    func noGeoTrackingInTheSimulator() async {
        #expect(await ARSessionManager.isGeoTrackingAvailableHere() == false)
    }
}
