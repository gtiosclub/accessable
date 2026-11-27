import Foundation
import Testing
@testable import AccessAble

private final class PointToScanTestMotion: DeviceMotionProviding, @unchecked Sendable {
    private let stream: AsyncStream<DeviceGravitySample>
    private let continuation: AsyncStream<DeviceGravitySample>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func gravitySamples() -> AsyncStream<DeviceGravitySample> { stream }

    func send(_ z: Double, at time: Date = .now) {
        continuation.yield(DeviceGravitySample(gravityZ: z, timestamp: time))
    }
}

private final class PointToScanTestLocation: LocationProvider, @unchecked Sendable {
    private let locations: AsyncStream<LocationSample>
    private let locationContinuation: AsyncStream<LocationSample>.Continuation
    private let headings: AsyncStream<HeadingSample>
    private let headingContinuation: AsyncStream<HeadingSample>.Continuation

    init() {
        (locations, locationContinuation) = AsyncStream.makeStream()
        (headings, headingContinuation) = AsyncStream.makeStream()
    }

    func locationSamples() -> AsyncStream<LocationSample> { locations }

    func headingSamples() -> AsyncStream<HeadingSample> { headings }

    func authorizationStates() -> AsyncStream<LocationAuthorization> {
        AsyncStream { $0.finish() }
    }

    func requestAuthorization() async {}

    func send(location: LocationSample) {
        locationContinuation.yield(location)
    }

    func send(heading: HeadingSample) {
        headingContinuation.yield(heading)
    }
}

@MainActor
struct PointToScanViewModelTests {
    private let origin = GeoCoordinate(latitude: 33.7756, longitude: -84.3963)
    private let clough = CampusNicknamePlace(
        name: "Clough Commons",
        nicknames: [],
        coordinate: GeoCoordinate(latitude: 33.7752, longitude: -84.3942),
        address: nil
    )

    private func makeModel(
        clock: ManualClock = ManualClock(),
        sink: RecordingSink = RecordingSink()
    ) -> (PointToScanViewModel, PointToScanTestLocation, PointToScanTestMotion, ManualClock, RecordingSink) {
        let location = PointToScanTestLocation()
        let motion = PointToScanTestMotion()
        let model = PointToScanViewModel(
            location: location,
            motion: motion,
            campus: CampusNicknameDictionary(places: [clough]),
            savedPlaces: { [] },
            poiProvider: StubPointToScanPOIProvider(places: []),
            announcements: sink,
            distances: { .imperial },
            clock: clock
        )
        return (model, location, motion, clock, sink)
    }

    private func heading(toward target: GeoCoordinate, at time: Date) -> HeadingSample {
        let degrees = GeoMath.bearing(from: origin, to: target)
        return HeadingSample(trueHeading: degrees, magneticHeading: degrees, accuracy: 5, timestamp: time)
    }

    /// Nested listen tasks need a few turns of the scheduler before they subscribe.
    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    @Test
    func silentWhenSettingOff() async throws {
        let (model, location, motion, _, sink) = makeModel()
        model.setEnabled(false)
        model.setHomeVisible(true)
        model.startIfNeeded()
        await settle()
        let fix = LocationSample(coordinate: origin, horizontalAccuracy: 5, timestamp: .now)
        location.send(location: fix)
        location.send(heading: heading(toward: clough.coordinate, at: fix.timestamp))
        motion.send(-0.95)
        await settle()
        #expect(sink.keys.isEmpty)
    }

    @Test
    func announcesPlaceWhenFlatAndEnabled() async throws {
        let clock = ManualClock()
        let sink = RecordingSink()
        let (model, location, motion, _, _) = makeModel(clock: clock, sink: sink)
        model.setEnabled(true)
        model.setHomeVisible(true)
        model.startIfNeeded()
        await settle()
        let fix = LocationSample(coordinate: origin, horizontalAccuracy: 5, timestamp: .now)
        motion.send(-0.95)
        await settle()
        location.send(location: fix)
        location.send(heading: heading(toward: clough.coordinate, at: fix.timestamp))
        await settle()
        try await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(300))
        await settle()
        #expect(sink.keys.contains("point-to-scan-start"))
        #expect(sink.keys.contains(where: { $0?.hasPrefix("point-to-scan:campus:") == true }))
    }

    @Test
    func muteStopsAnnouncements() async throws {
        let sink = RecordingSink()
        let (model, location, motion, _, _) = makeModel(sink: sink)
        model.setEnabled(true)
        model.setHomeVisible(true)
        model.scanMuted = true
        model.startIfNeeded()
        await settle()
        motion.send(-0.95)
        let fix = LocationSample(coordinate: origin, horizontalAccuracy: 5, timestamp: .now)
        location.send(location: fix)
        location.send(heading: heading(toward: clough.coordinate, at: fix.timestamp))
        await settle()
        #expect(sink.keys.isEmpty)
    }

    @Test
    func notFlatMeansSilence() async throws {
        let sink = RecordingSink()
        let (model, location, motion, _, _) = makeModel(sink: sink)
        model.setEnabled(true)
        model.setHomeVisible(true)
        model.startIfNeeded()
        await settle()
        motion.send(-0.5)
        let fix = LocationSample(coordinate: origin, horizontalAccuracy: 5, timestamp: .now)
        location.send(location: fix)
        location.send(heading: heading(toward: clough.coordinate, at: fix.timestamp))
        await settle()
        #expect(sink.keys.isEmpty)
    }
}
