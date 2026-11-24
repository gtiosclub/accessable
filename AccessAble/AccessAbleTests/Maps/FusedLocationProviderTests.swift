import Foundation
import Testing
@testable import AccessAble

private let start = Date(timeIntervalSince1970: 1_700_000_000)
private let techGreen = GeoCoordinate(latitude: 33.77450, longitude: -84.39740)

/// `metresNorth` of Tech Green, `seconds` after `start`.
private func gps(_ seconds: TimeInterval, metresNorth: Double = 0, accuracy: Double = 10) -> LocationSample {
    LocationSample(
        coordinate: GeoCoordinate(latitude: techGreen.latitude + metresNorth / 111_000, longitude: techGreen.longitude),
        horizontalAccuracy: accuracy, timestamp: start + seconds,
        speed: 1.3, speedAccuracy: 0.3, course: 0, courseAccuracy: 15
    )
}

private func ar(_ seconds: TimeInterval, metresNorth: Double = 0, accuracy: GeoTrackingUpdate.Accuracy = .high)
    -> LocationSample {
    ARGeoLocationProvider.sample(from: update(seconds, metresNorth: metresNorth, accuracy: accuracy))!
}

private func update(_ seconds: TimeInterval, metresNorth: Double = 0, accuracy: GeoTrackingUpdate.Accuracy = .high,
                    state: GeoTrackingUpdate.State = .localized) -> GeoTrackingUpdate {
    GeoTrackingUpdate(
        state: state, accuracy: accuracy,
        coordinate: GeoCoordinate(latitude: techGreen.latitude + metresNorth / 111_000, longitude: techGreen.longitude),
        heading: 0, timestamp: start + seconds
    )
}

/// Holds back whoever waits on it until it opens.
private final class Gate: Sendable {
    private let (stream, continuation) = AsyncStream.makeStream(of: Void.self)

    func open() { continuation.finish() }
    func opened() async { for await _ in stream {} }
}

private struct ScriptedGeoTracking: GeoTrackingProviding {
    let updates: [GeoTrackingUpdate]
    /// Holds the updates back until it opens.
    var gate: Gate?

    func setGeoTrackingWanted(_ wanted: Bool) async {}
    func geoTrackingUpdates() -> AsyncStream<GeoTrackingUpdate> {
        AsyncStream { continuation in
            let task = Task {
                await gate?.opened()
                updates.forEach { continuation.yield($0) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Sends `samples`, then stays open like Core Location does.
private struct ScriptedGPS: LocationProvider {
    let samples: [LocationSample]

    func locationSamples() -> AsyncStream<LocationSample> {
        AsyncStream { continuation in samples.forEach { continuation.yield($0) } }
    }
    func headingSamples() -> AsyncStream<HeadingSample> { AsyncStream { _ in } }
    func authorizationStates() -> AsyncStream<LocationAuthorization> { AsyncStream { _ in } }
    func requestAuthorization() async {}
}

struct ARGeoLocationProviderTests {
    @Test
    func readingOnlyOnceLocalizedWithAKnownAccuracy() {
        #expect(ARGeoLocationProvider.sample(from: update(0))?.horizontalAccuracy == 5)
        #expect(ARGeoLocationProvider.sample(from: update(0, accuracy: .medium))?.horizontalAccuracy == 10)
        #expect(ARGeoLocationProvider.sample(from: update(0))?.source == .ar)
        #expect(ARGeoLocationProvider.sample(from: update(0, accuracy: .low))?.horizontalAccuracy == 20)
        #expect(ARGeoLocationProvider.sample(from: update(0, accuracy: .undetermined)) == nil)
        #expect(ARGeoLocationProvider.sample(from: update(0, state: .localizing)) == nil)

        var noPosition = update(0)
        noPosition.coordinate = nil
        #expect(ARGeoLocationProvider.sample(from: noPosition) == nil)
    }

    @Test(arguments: [GeoTrackingUpdate.State.stopped, .localizing, .initializing, .notAvailable])
    func everyUpdateWithoutAPositionIsALoss(state: GeoTrackingUpdate.State) {
        #expect(ARGeoLocationProvider.reading(from: update(0, state: state)) == .arLost)
        #expect(ARGeoLocationProvider.reading(from: update(0, accuracy: .undetermined)) == .arLost)
        #expect(ARGeoLocationProvider.reading(from: update(0)) == .ar(ar(0)))
    }
}

/// Feeds a GPS fix and, half a second later, an AR reading each second from `seconds` until AR takes over, which
/// takes three. Returns when the last was.
@discardableResult
private func lockOn(_ fusion: inout LocationFusion, at seconds: TimeInterval = 0) -> TimeInterval {
    for second in 0..<LocationFusion.arEntryReadings {
        let time = seconds + Double(second)
        #expect(fusion.receive(.gps(gps(time)))?.source == .gps)
        let received = fusion.receive(.ar(ar(time + 0.5)))
        #expect(received?.source == (second == LocationFusion.arEntryReadings - 1 ? .ar : nil))
    }
    return seconds + Double(LocationFusion.arEntryReadings - 1) + 0.5
}

/// How often the passed-on readings change source.
private func switches(_ samples: [LocationSample]) -> Int {
    zip(samples, samples.dropFirst()).filter { $0.source != $1.source }.count
}

struct LocationFusionTests {
    @Test
    func gpsPassesUntilGeoTrackingLocksOn() {
        var fusion = LocationFusion()

        #expect(fusion.receive(.gps(gps(0)))?.source == .gps)
        #expect(fusion.receive(.ar(ar(0.5, accuracy: .low))) == nil)
        #expect(fusion.receive(.gps(gps(1)))?.source == .gps)
    }

    @Test
    func switchingToARTakesThreeGoodReadingsOverTwoSeconds() {
        var fusion = LocationFusion()
        _ = fusion.receive(.gps(gps(0)))

        #expect(fusion.receive(.ar(ar(0.1))) == nil)
        #expect(fusion.receive(.ar(ar(0.6))) == nil)
        // three, but over only a second
        #expect(fusion.receive(.ar(ar(1.1))) == nil)
        #expect(fusion.receive(.ar(ar(2.1)))?.source == .ar)
    }

    @Test
    func aCoarseReadingRestartsTheRunToAR() {
        var fusion = LocationFusion()
        _ = fusion.receive(.gps(gps(0)))

        #expect(fusion.receive(.ar(ar(0.5))) == nil)
        #expect(fusion.receive(.ar(ar(1.5))) == nil)
        #expect(fusion.receive(.ar(ar(2.5, accuracy: .low))) == nil)
        _ = fusion.receive(.gps(gps(3)))
        #expect(fusion.receive(.ar(ar(3.5))) == nil)
        #expect(fusion.receive(.ar(ar(4.5))) == nil)
        #expect(fusion.receive(.ar(ar(5.5)))?.source == .ar)
    }

    @Test(arguments: [GeoTrackingUpdate.Accuracy.medium, .high])
    func lockedOnARReplacesGPSAndBorrowsItsMovement(accuracy: GeoTrackingUpdate.Accuracy) throws {
        var fusion = LocationFusion()
        let time = lockOn(&fusion)

        let received = fusion.receive(.ar(ar(time + 1, metresNorth: 4, accuracy: accuracy)))
        let sample = try #require(received)

        #expect(sample.source == .ar)
        #expect(sample.coordinate == ar(0, metresNorth: 4).coordinate)
        #expect(sample.speed == 1.3 && sample.course == 0)
        #expect(fusion.receive(.gps(gps(time + 1.2))) == nil)
    }

    @Test
    func arBorrowsMovementOnlyFromARecentFix() throws {
        var fusion = LocationFusion()
        let time = lockOn(&fusion)

        // the last fix was half a second before `time`
        #expect(fusion.receive(.ar(ar(time + 1.5)))?.speed == 1.3)
        // 3.5 s old, it still checks AR, but its course may be from before a turn
        let received = fusion.receive(.ar(ar(time + 3)))
        let sample = try #require(received)
        #expect(sample.speed == nil && sample.course == nil)
    }

    @Test
    func gpsReturnsWhenARReadingsStop() {
        var fusion = LocationFusion()
        let time = lockOn(&fusion)

        #expect(fusion.receive(.gps(gps(time + 2))) == nil)
        #expect(fusion.receive(.gps(gps(time + 2.1)))?.source == .gps)
        // and switching back takes a whole run
        #expect(fusion.receive(.ar(ar(time + 2.5))) == nil)
    }

    @Test
    func oneCoarseReadingKeepsARButTwoInARowEndIt() {
        var fusion = LocationFusion()
        let time = lockOn(&fusion)

        #expect(fusion.receive(.ar(ar(time + 1, accuracy: .low))) == nil)
        #expect(fusion.receive(.gps(gps(time + 1.2))) == nil)
        #expect(fusion.receive(.ar(ar(time + 2)))?.source == .ar)

        #expect(fusion.receive(.ar(ar(time + 3, accuracy: .low))) == nil)
        #expect(fusion.receive(.ar(ar(time + 4, accuracy: .low))) == nil)
        #expect(fusion.receive(.gps(gps(time + 4.2)))?.source == .gps)
        #expect(fusion.receive(.ar(ar(time + 5))) == nil)
    }

    @Test
    func accuracyFlickeringToLowSwitchesAtMostOnce() {
        var fusion = LocationFusion()
        var passed: [LocationSample] = []
        for second in 0..<30 {
            let time = Double(second)
            if let sample = fusion.receive(.gps(gps(time))) { passed.append(sample) }
            let accuracy: GeoTrackingUpdate.Accuracy = second.isMultiple(of: 2) ? .high : .low
            if let sample = fusion.receive(.ar(ar(time + 0.5, accuracy: accuracy))) { passed.append(sample) }
        }

        #expect(switches(passed) <= 1)
    }

    @Test
    func flickeringAfterLockingOnStaysOnAR() {
        var fusion = LocationFusion()
        let time = lockOn(&fusion)
        var passed: [LocationSample] = []
        for second in 1...30 {
            let at = time + Double(second)
            if let sample = fusion.receive(.gps(gps(at - 0.5))) { passed.append(sample) }
            let accuracy: GeoTrackingUpdate.Accuracy = second.isMultiple(of: 2) ? .high : .low
            if let sample = fusion.receive(.ar(ar(at, accuracy: accuracy))) { passed.append(sample) }
        }

        #expect(passed.allSatisfy { $0.source == .ar })
    }

    @Test
    func arDisagreeingWithGPSEndsAtOnce() {
        var fusion = LocationFusion()
        let time = lockOn(&fusion)

        // GPS is 10 m accurate, so AR may be 30 m off
        #expect(fusion.receive(.ar(ar(time + 1, metresNorth: 29)))?.source == .ar)
        #expect(fusion.receive(.ar(ar(time + 2, metresNorth: 31))) == nil)
        #expect(fusion.receive(.gps(gps(time + 2.1)))?.source == .gps)
    }

    @Test
    func agreementNearTheLimitDoesNotFlap() {
        var fusion = LocationFusion()
        let time = lockOn(&fusion)
        var passed: [LocationSample] = []
        for second in 1...30 {
            let at = time + Double(second)
            if let sample = fusion.receive(.gps(gps(at - 0.5))) { passed.append(sample) }
            let north: Double = second.isMultiple(of: 2) ? 29 : 31
            if let sample = fusion.receive(.ar(ar(at, metresNorth: north))) { passed.append(sample) }
        }

        #expect(passed.first?.source == .gps)
        #expect(switches(passed) == 0)
    }

    @Test
    func arComesBackAfterAWholeNewRun() {
        var fusion = LocationFusion()
        let time = lockOn(&fusion)
        #expect(fusion.receive(.ar(ar(time + 1, metresNorth: 40))) == nil)

        let back = lockOn(&fusion, at: time + 1.5)
        #expect(fusion.receive(.gps(gps(back + 0.2))) == nil)
    }

    @Test
    func gpsReturnsAsSoonAsGeoTrackingStops() {
        var fusion = LocationFusion()
        let time = lockOn(&fusion)

        #expect(fusion.receive(ARGeoLocationProvider.reading(from: update(time + 0.3, state: .stopped))) == nil)
        #expect(fusion.receive(.gps(gps(time + 0.5)))?.source == .gps)
        #expect(fusion.receive(.ar(ar(time + 1))) == nil)
    }

    @Test
    func noGPSYetMeansNoAR() {
        var fusion = LocationFusion()

        for second in 0..<10 {
            #expect(fusion.receive(.ar(ar(Double(second)))) == nil)
        }
        #expect(fusion.receive(.gps(gps(10)))?.source == .gps)
    }

    @Test
    func staleGPSCannotLetARInButDoesNotEndIt() {
        var fusion = LocationFusion()
        _ = fusion.receive(.gps(gps(0)))
        for second in 6..<10 {
            #expect(fusion.receive(.ar(ar(Double(second)))) == nil)
        }

        let time = lockOn(&fusion, at: 20)
        // GPS goes quiet; once its last fix is stale, AR goes on unchecked, even far from that fix
        for second in 1...10 {
            let received = fusion.receive(.ar(ar(time + Double(second), metresNorth: second < 5 ? 0 : 100)))
            #expect(received?.source == .ar)
        }
    }
}

struct FusedLocationProviderTests {
    @Test
    func withoutGeoTrackingItIsGPS() async {
        let fused = FusedLocationProvider(gps: ScriptedGPS(samples: [gps(0)]), geoTracking: nil)

        for await sample in fused.locationSamples() {
            #expect(sample == gps(0))
            break
        }
    }

    @Test
    func geoTrackingReadingsComeThroughMarkedAR() async {
        // AR is checked against GPS, so its readings wait until the GPS fix has come through
        let gate = Gate()
        let updates = [update(0.2, accuracy: .low), update(0.5), update(1.5), update(2.5)]
        let fused = FusedLocationProvider(
            gps: ScriptedGPS(samples: [gps(0)]), geoTracking: ScriptedGeoTracking(updates: updates, gate: gate)
        )

        var received: [LocationSample] = []
        for await sample in fused.locationSamples() {
            received.append(sample)
            if sample.source == .ar { break }
            gate.open()
        }
        #expect(received.map(\.source) == [.gps, .ar])
        #expect(received.last?.timestamp == start + 2.5)
    }
}
