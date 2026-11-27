import Foundation
import Observation

/// Point-to-scan on the home screen: flat phone + slow turn names nearby places.
@MainActor
@Observable
final class PointToScanViewModel {
    static let startCueText = "Scanning. Turn slowly."
    static let startCueKey = "point-to-scan-start"

    var scanMuted = false

    @ObservationIgnored private let location: any LocationProvider
    @ObservationIgnored private let motion: any DeviceMotionProviding
    @ObservationIgnored private let campus: CampusNicknameDictionary
    @ObservationIgnored private let savedPlaces: @Sendable () -> [SavedPlace]
    @ObservationIgnored private let poiProvider: any PointToScanPOIProviding
    @ObservationIgnored private let announcements: any AnnouncementSink
    @ObservationIgnored private let distances: @Sendable () -> DistanceFormatter
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let now: @Sendable () -> Date

    @ObservationIgnored private var settingEnabled = false
    @ObservationIgnored private var homeVisible = false
    @ObservationIgnored private var sceneActive = true
    @ObservationIgnored private var flatDetector = FlatPhoneDetector()
    @ObservationIgnored private var isFlat = false
    @ObservationIgnored private var wasScanning = false

    @ObservationIgnored private var headingEstimator = HeadingEstimator()
    @ObservationIgnored private var locationFix: LocationSample?
    @ObservationIgnored private var mapKitPlaces: [PointToScanPlace] = []
    @ObservationIgnored private var lastPOIOrigin: GeoCoordinate?
    @ObservationIgnored private var speech = PointToScanSpeechPolicy(clock: ContinuousClock())
    @ObservationIgnored private var placesByID: [String: PointToScanPlace] = [:]
    @ObservationIgnored private var listenerTask: Task<Void, Never>?

    init(
        location: any LocationProvider,
        motion: any DeviceMotionProviding,
        campus: CampusNicknameDictionary,
        savedPlaces: @escaping @Sendable () -> [SavedPlace],
        poiProvider: any PointToScanPOIProviding,
        announcements: any AnnouncementSink,
        distances: @escaping @Sendable () -> DistanceFormatter,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.location = location
        self.motion = motion
        self.campus = campus
        self.savedPlaces = savedPlaces
        self.poiProvider = poiProvider
        self.announcements = announcements
        self.distances = distances
        self.clock = clock
        self.now = now
        self.speech = PointToScanSpeechPolicy(clock: clock)
    }

    func setEnabled(_ enabled: Bool) {
        settingEnabled = enabled
        if !enabled { endScanning() }
        refreshActivity()
    }

    func setHomeVisible(_ visible: Bool) {
        homeVisible = visible
        if !visible { endScanning() }
        refreshActivity()
    }

    func setSceneActive(_ active: Bool) {
        sceneActive = active
        if !active { endScanning() }
        refreshActivity()
    }

    func toggleMute() {
        scanMuted.toggle()
        if scanMuted { endScanning() }
        refreshActivity()
    }

    func startIfNeeded() {
        guard listenerTask == nil else { return }
        listenerTask = Task { await listen() }
    }

    func stop() {
        listenerTask?.cancel()
        listenerTask = nil
        endScanning()
    }

    private var mayScan: Bool {
        settingEnabled && homeVisible && sceneActive && isFlat && !scanMuted
    }

    private func refreshActivity() {
        if mayScan {
            Task { await beginScanningIfNeeded() }
        } else {
            endScanning()
        }
    }

    private func endScanning() {
        wasScanning = false
        speech.resetScanSession()
    }

    private func listen() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [location] in
                for await sample in location.locationSamples() {
                    guard !Task.isCancelled else { return }
                    await self.handleLocation(sample)
                }
            }
            group.addTask { [location] in
                for await sample in location.headingSamples() {
                    guard !Task.isCancelled else { return }
                    await self.handleHeading(sample)
                }
            }
            group.addTask { [motion] in
                for await sample in motion.gravitySamples() {
                    guard !Task.isCancelled else { return }
                    await self.handleGravity(sample)
                }
            }
        }
    }

    private func handleLocation(_ sample: LocationSample) {
        locationFix = sample
        headingEstimator.update(with: sample)
        guard mayScan else { return }
        if PointToScanSelection.shouldRefetchPOIs(from: lastPOIOrigin, to: sample.coordinate) {
            lastPOIOrigin = sample.coordinate
            let center = sample.coordinate
            Task { await refreshMapKit(center: center) }
        }
        evaluateSelection()
    }

    private func handleHeading(_ sample: HeadingSample) {
        headingEstimator.update(with: sample)
        guard mayScan else { return }
        evaluateSelection()
    }

    private func handleGravity(_ sample: DeviceGravitySample) {
        let flat = flatDetector.update(gravityZ: sample.gravityZ)
        guard flat != isFlat else { return }
        isFlat = flat
        if flat {
            refreshActivity()
        } else {
            endScanning()
        }
    }

    private func refreshMapKit(center: GeoCoordinate) async {
        let places = await poiProvider.fetch(center: center)
        guard !Task.isCancelled else { return }
        mapKitPlaces = places
        rebuildPlaceIndex()
        evaluateSelection()
    }

    private func rebuildPlaceIndex() {
        let merged = PointToScanSelection.mergedPlaces(
            campus: campus,
            saved: savedPlaces(),
            mapKit: mapKitPlaces
        )
        placesByID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
    }

    private func beginScanningIfNeeded() async {
        guard mayScan else { return }
        rebuildPlaceIndex()
        if let fix = locationFix, PointToScanSelection.shouldRefetchPOIs(from: lastPOIOrigin, to: fix.coordinate) {
            lastPOIOrigin = fix.coordinate
            await refreshMapKit(center: fix.coordinate)
        }
        if !wasScanning {
            wasScanning = true
            await speech.scanStartCueIfNeeded { [self] in
                await self.announceStartCue()
            }
        }
        evaluateSelection()
    }

    private func evaluateSelection() {
        guard mayScan, wasScanning else { return }
        guard let fix = locationFix, let heading = headingEstimator.heading(at: now()) else {
            speech.userTurnedAway()
            return
        }
        let merged = PointToScanSelection.mergedPlaces(
            campus: campus,
            saved: savedPlaces(),
            mapKit: mapKitPlaces
        )
        guard let match = PointToScanSelection.bestMatch(
            origin: fix.coordinate,
            headingDegrees: heading.degrees,
            places: merged
        ) else {
            speech.userTurnedAway()
            return
        }
        placesByID[match.id] = match
        speech.schedule(placeID: match.id) { [self] placeID in
            await self.announce(placeID: placeID, from: fix.coordinate)
        }
    }

    private func announceStartCue() async {
        await announcements.submit(AnnouncementEvent(
            category: .landmark,
            priority: .normal,
            text: Self.startCueText,
            source: .location,
            dedupKey: Self.startCueKey
        ))
    }

    private func announce(placeID: String, from origin: GeoCoordinate) async {
        guard mayScan, let place = placesByID[placeID] else { return }
        let metres = GeoMath.distance(from: origin, to: place.coordinate)
        guard metres.isFinite else { return }
        let text = "\(place.name), \(distances().words(metres))."
        await announcements.submit(AnnouncementEvent(
            category: .landmark,
            priority: .normal,
            text: text,
            distance: metres,
            source: .location,
            dedupKey: "point-to-scan:\(placeID)"
        ))
    }
}