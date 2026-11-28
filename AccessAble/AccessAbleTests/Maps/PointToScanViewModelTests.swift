import Foundation
import Synchronization
import Testing
@testable import AccessAble

/// A fresh stream per subscriber, telling the test when each one starts and ends.
private final class TestFeed<Element: Sendable>: Sendable {
    enum Event: Sendable, Equatable { case started, ended }

    private let current = Mutex<AsyncStream<Element>.Continuation?>(nil)
    private let count = Mutex(0)
    private let events: AsyncStream<Event>
    private let eventContinuation: AsyncStream<Event>.Continuation

    init() {
        (events, eventContinuation) = AsyncStream.makeStream()
    }

    var subscriptions: Int { count.withLock { $0 } }

    func stream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        continuation.onTermination = { [eventContinuation] _ in eventContinuation.yield(.ended) }
        current.withLock { $0 = continuation }
        count.withLock { $0 += 1 }
        eventContinuation.yield(.started)
        return stream
    }

    func send(_ element: Element) {
        current.withLock { $0 }?.yield(element)
    }

    /// Returns at the next `event` not yet waited past.
    func waitFor(_ event: Event) async {
        for await next in events where next == event { return }
    }
}

private final class ScanLocation: LocationProvider {
    let fixes = TestFeed<LocationSample>()
    let headings = TestFeed<HeadingSample>()

    func locationSamples() -> AsyncStream<LocationSample> { fixes.stream() }

    func headingSamples() -> AsyncStream<HeadingSample> { headings.stream() }

    func authorizationStates() -> AsyncStream<LocationAuthorization> {
        AsyncStream { $0.finish() }
    }

    func requestAuthorization() async {}
}

private final class ScanMotion: DeviceMotionProviding {
    let gravity = TestFeed<DeviceGravitySample>()

    func gravitySamples() -> AsyncStream<DeviceGravitySample> { gravity.stream() }
}

/// Reports each fetch's center, and fails as many fetches as the test asks.
private final class ScanPOIs: PointToScanPOIProviding {
    private let failuresLeft = Mutex(0)
    private let calls: AsyncStream<GeoCoordinate>
    private let callContinuation: AsyncStream<GeoCoordinate>.Continuation

    init() {
        (calls, callContinuation) = AsyncStream.makeStream()
    }

    func fail(next count: Int) {
        failuresLeft.withLock { $0 = count }
    }

    func fetch(center: GeoCoordinate) async throws -> [PointToScanPlace] {
        callContinuation.yield(center)
        let fails = failuresLeft.withLock { left in
            guard left > 0 else { return false }
            left -= 1
            return true
        }
        if fails { throw URLError(.notConnectedToInternet) }
        return []
    }

    func nextCall() async -> GeoCoordinate? {
        for await call in calls { return call }
        return nil
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PointToScanViewModelTests {
    enum Teardown: CaseIterable, Sendable { case leaveHome, appInactive, settingOff, sheet, mute }

    private let origin = GeoCoordinate(latitude: 33.7756, longitude: -84.3963)
    private let clough = CampusNicknamePlace(
        name: "Clough Commons",
        nicknames: [],
        coordinate: GeoCoordinate(latitude: 33.7752, longitude: -84.3942),
        address: nil
    )
    private let cloughKey = "point-to-scan:campus:Clough Commons"

    private let location = ScanLocation()
    private let motion = ScanMotion()
    private let clock = ManualClock()
    private let date = ManualDate()
    private let sink = RecordingSink()
    private let pois = ScanPOIs()
    private let model: PointToScanViewModel

    init() {
        model = PointToScanViewModel(
            location: location,
            motion: motion,
            campus: CampusNicknameDictionary(places: [clough]),
            savedPlaces: { [] },
            poiProvider: pois,
            announcements: sink,
            distances: { .imperial },
            clock: clock,
            now: { [date] in date.now }
        )
    }

    private func showHome() {
        model.setEnabled(true)
        model.setSceneActive(true)
        model.setHomeVisible(true)
    }

    /// Returns once scanning has subscribed to location and heading.
    private func holdFlat() async {
        motion.gravity.send(DeviceGravitySample(gravityZ: -0.95, timestamp: date.now))
        await location.fixes.waitFor(.started)
        await location.headings.waitFor(.started)
    }

    private func fix(_ coordinate: GeoCoordinate, speed: Double? = nil, course: Double? = nil) -> LocationSample {
        LocationSample(
            coordinate: coordinate,
            horizontalAccuracy: 5,
            timestamp: date.now,
            speed: speed,
            course: course,
            courseAccuracy: course == nil ? nil : 5
        )
    }

    private func pointAtClough() {
        let degrees = GeoMath.bearing(from: origin, to: clough.coordinate)
        location.headings.send(HeadingSample(
            trueHeading: degrees,
            magneticHeading: degrees,
            accuracy: 5,
            timestamp: date.now
        ))
    }

    @Test
    func subscribesToNothingWithTheSettingOff() {
        model.setEnabled(false)
        model.setSceneActive(true)
        model.setHomeVisible(true)
        #expect(motion.gravity.subscriptions == 0)
        #expect(location.fixes.subscriptions == 0)
        #expect(location.headings.subscriptions == 0)
    }

    @Test
    func watchesMotionOnlyOnceEveryConditionHolds() {
        model.setEnabled(true)
        model.setHomeVisible(true)
        #expect(motion.gravity.subscriptions == 0)
        model.setSceneActive(true)
        #expect(motion.gravity.subscriptions == 1)
        #expect(location.fixes.subscriptions == 0)
        #expect(location.headings.subscriptions == 0)
    }

    @Test
    func announcesPlacePointedAtWhenFlat() async throws {
        showHome()
        await holdFlat()
        await sink.waitFor(PointToScanViewModel.startCueKey)
        location.fixes.send(fix(origin))
        pointAtClough()
        try await clock.waitForSleepers(1)
        clock.advance(by: PointToScanSpeechPolicy.holdDuration)
        await sink.waitFor(cloughKey)
        #expect(sink.keys == [PointToScanViewModel.startCueKey, cloughKey])
    }

    @Test
    func usesTheCompassNotTheWalkingCourse() async throws {
        showHome()
        await holdFlat()
        let away = GeoMath.bearing(from: origin, to: clough.coordinate) + 180
        location.fixes.send(fix(origin, speed: 1.5, course: away.truncatingRemainder(dividingBy: 360)))
        pointAtClough()
        try await clock.waitForSleepers(1)
        clock.advance(by: PointToScanSpeechPolicy.holdDuration)
        await sink.waitFor(cloughKey)
    }

    @Test(arguments: Teardown.allCases)
    func stopsEverything(on teardown: Teardown) async {
        showHome()
        await holdFlat()
        switch teardown {
        case .leaveHome: model.setHomeVisible(false)
        case .appInactive: model.setSceneActive(false)
        case .settingOff: model.setEnabled(false)
        case .sheet: model.setHomeCovered(true)
        case .mute: model.toggleMute()
        }
        await motion.gravity.waitFor(.ended)
        await location.fixes.waitFor(.ended)
        await location.headings.waitFor(.ended)
        switch teardown {
        case .leaveHome: model.setHomeVisible(true)
        case .appInactive: model.setSceneActive(true)
        case .settingOff: model.setEnabled(true)
        case .sheet: model.setHomeCovered(false)
        case .mute: model.toggleMute()
        }
        #expect(motion.gravity.subscriptions == 2)
        #expect(location.fixes.subscriptions == 1)
    }

    @Test
    func tiltingUpStopsLocationAndCuesEachNewScanOnce() async {
        showHome()
        await holdFlat()
        await sink.waitFor(PointToScanViewModel.startCueKey)
        pointAtClough()
        motion.gravity.send(DeviceGravitySample(gravityZ: -0.5, timestamp: date.now))
        await location.fixes.waitFor(.ended)
        await location.headings.waitFor(.ended)
        #expect(motion.gravity.subscriptions == 1)
        await holdFlat()
        await sink.waitFor(PointToScanViewModel.startCueKey)
        #expect(sink.keys == [PointToScanViewModel.startCueKey, PointToScanViewModel.startCueKey])
    }

    @Test
    func refetchesPlacesOnlyAfterMovingFiftyMetres() async {
        showHome()
        await holdFlat()
        location.fixes.send(fix(origin))
        let first = await pois.nextCall()
        await model.poiTask?.value
        // about 44 m, then 56 m north
        let near = GeoCoordinate(latitude: origin.latitude + 0.0004, longitude: origin.longitude)
        let far = GeoCoordinate(latitude: origin.latitude + 0.0005, longitude: origin.longitude)
        location.fixes.send(fix(near))
        location.fixes.send(fix(far))
        let second = await pois.nextCall()
        #expect(first == origin)
        #expect(second == far)
    }

    @Test
    func retriesAFailedFetchAfterTheDelay() async {
        pois.fail(next: 1)
        showHome()
        await holdFlat()
        location.fixes.send(fix(origin))
        _ = await pois.nextCall()
        await model.poiTask?.value
        // the delay goes by the fixes' own timestamps
        let near = GeoCoordinate(latitude: origin.latitude + 0.0001, longitude: origin.longitude)
        date.advance(by: PointToScanViewModel.poiRetryDelay - 1)
        location.fixes.send(fix(near))
        date.advance(by: 1)
        location.fixes.send(fix(origin))
        let retry = await pois.nextCall()
        #expect(retry == origin)
    }
}
