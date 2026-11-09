import Foundation
import Testing
@testable import AccessAble

/// Never has a fix, like a phone indoors with Location off.
private struct NoFixLocationProvider: LocationProvider {
    func locationSamples() -> AsyncStream<LocationSample> {
        AsyncStream { _ in }
    }

    func headingSamples() -> AsyncStream<HeadingSample> {
        AsyncStream { continuation in continuation.finish() }
    }

    func authorizationStates() -> AsyncStream<LocationAuthorization> {
        AsyncStream { continuation in continuation.finish() }
    }

    func requestAuthorization() async {}
}

/// Only rough fixes, too vague to name a street.
private struct RoughFixLocationProvider: LocationProvider {
    func locationSamples() -> AsyncStream<LocationSample> {
        AsyncStream { continuation in
            continuation.yield(LocationSample(
                coordinate: GeoCoordinate(latitude: 33.7756, longitude: -84.3963),
                horizontalAccuracy: 900,
                timestamp: .now
            ))
        }
    }

    func headingSamples() -> AsyncStream<HeadingSample> {
        AsyncStream { continuation in continuation.finish() }
    }

    func authorizationStates() -> AsyncStream<LocationAuthorization> {
        AsyncStream { continuation in continuation.finish() }
    }

    func requestAuthorization() async {}
}

struct LocationDescriberTests {
    @Test
    func givesUpWhenNoFixComes() async {
        let describer = LocationDescriber(location: NoFixLocationProvider(), fixTimeout: .milliseconds(100))
        #expect(await describer.currentLocationDescription() == nil)
    }

    @Test
    func roughFixesDontNameAStreet() async {
        let describer = LocationDescriber(location: RoughFixLocationProvider(), fixTimeout: .milliseconds(100))
        #expect(await describer.currentLocationDescription() == nil)
    }
}
