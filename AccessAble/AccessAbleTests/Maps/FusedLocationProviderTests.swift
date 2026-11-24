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

private struct ScriptedGeoTracking: GeoTrackingProviding {
    let updates: [GeoTrackingUpdate]

    func setGeoTrackingWanted(_ wanted: Bool) async {}
    func geoTrackingUpdates() -> AsyncStream<GeoTrackingUpdate> {
        AsyncStream { continuation in updates.forEach { continuation.yield($0) } }
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
}

struct LocationFusionTests {
    @Test
    func gpsPassesUntilGeoTrackingLocksOn() {
        var fusion = LocationFusion()

        #expect(fusion.receive(.gps(gps(0)))?.source == .gps)
        #expect(fusion.receive(.ar(ar(0.5, accuracy: .low))) == nil)
        #expect(fusion.receive(.gps(gps(1)))?.source == .gps)
    }

    @Test(arguments: [GeoTrackingUpdate.Accuracy.medium, .high])
    func lockedOnARReplacesGPSAndBorrowsItsMovement(accuracy: GeoTrackingUpdate.Accuracy) throws {
        var fusion = LocationFusion()
        _ = fusion.receive(.gps(gps(0)))

        let received = fusion.receive(.ar(ar(0.5, metresNorth: 4, accuracy: accuracy)))
        let sample = try #require(received)

        #expect(sample.source == .ar)
        #expect(sample.coordinate == ar(0.5, metresNorth: 4).coordinate)
        #expect(sample.speed == 1.3 && sample.course == 0)
        #expect(fusion.receive(.gps(gps(1))) == nil)
    }

    @Test
    func gpsReturnsWhenARStopsOrLosesAccuracy() {
        var fusion = LocationFusion()
        _ = fusion.receive(.ar(ar(0)))

        #expect(fusion.receive(.gps(gps(2))) == nil)
        #expect(fusion.receive(.gps(gps(2.1)))?.source == .gps)

        _ = fusion.receive(.ar(ar(3)))
        #expect(fusion.receive(.ar(ar(3.5, accuracy: .low))) == nil)
        #expect(fusion.receive(.gps(gps(3.6)))?.source == .gps)
    }

    @Test
    func arFarFromGPSIsNotTrusted() {
        var fusion = LocationFusion()
        _ = fusion.receive(.gps(gps(0, accuracy: 10)))

        #expect(fusion.receive(.ar(ar(1, metresNorth: 29))) != nil)
        #expect(fusion.receive(.ar(ar(2, metresNorth: 31))) == nil)
        #expect(fusion.receive(.gps(gps(2.5)))?.source == .gps)
    }

    @Test
    func staleGPSNeitherVetoesNorLendsMovement() throws {
        var fusion = LocationFusion()
        _ = fusion.receive(.gps(gps(0)))

        let received = fusion.receive(.ar(ar(5.1, metresNorth: 100)))
        let sample = try #require(received)

        #expect(sample.speed == nil && sample.course == nil)
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
        let fused = FusedLocationProvider(
            gps: ScriptedGPS(samples: []), geoTracking: ScriptedGeoTracking(updates: [update(0, accuracy: .low), update(1)])
        )

        for await sample in fused.locationSamples() {
            #expect(sample.source == .ar)
            #expect(sample.timestamp == start + 1)
            break
        }
    }

    @Test
    func recordingsFromBeforeSourceDecodeAsGPS() throws {
        let old = #"{"coordinate":{"latitude":33.7745,"longitude":-84.3974},"horizontalAccuracy":5,"timestamp":0}"#
        let sample = try JSONDecoder().decode(LocationSample.self, from: Data(old.utf8))

        #expect(sample.source == .gps)
        let arSample = LocationSample(coordinate: techGreen, horizontalAccuracy: 3, timestamp: start, source: .ar)
        #expect(try JSONDecoder().decode(LocationSample.self, from: JSONEncoder().encode(arSample)) == arSample)
    }
}
