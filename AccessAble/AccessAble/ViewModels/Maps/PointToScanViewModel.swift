import Foundation
import Observation
import os

private let log = Logger(subsystem: "AccessAble", category: "PointToScan")

/// Point-to-scan on the home screen: flat phone + slow turn names nearby places.
///
/// Motion runs only while the setting is on, the home screen is showing and uncovered, the app is active and the
/// scan isn't muted; location and heading only while the phone is also flat.
@MainActor
@Observable
final class PointToScanViewModel {
    static let startCueText = "Scanning. Turn slowly."
    static let startCueKey = "point-to-scan-start"
    /// Seconds, by fix time, before a failed MapKit fetch is tried again.
    static let poiRetryDelay: TimeInterval = 10

    private(set) var scanMuted = false

    @ObservationIgnored private let location: any LocationProvider
    @ObservationIgnored private let motion: any DeviceMotionProviding
    @ObservationIgnored private let campus: CampusNicknameDictionary
    @ObservationIgnored private let savedPlaces: @Sendable () -> [SavedPlace]
    @ObservationIgnored private let poiProvider: any PointToScanPOIProviding
    @ObservationIgnored private let announcements: any AnnouncementSink
    @ObservationIgnored private let distances: @Sendable () -> DistanceFormatter
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let speech: PointToScanSpeechPolicy

    @ObservationIgnored private var settingEnabled = false
    @ObservationIgnored private var homeVisible = false
    @ObservationIgnored private var sceneActive = false
    @ObservationIgnored private var homeCovered = false
    @ObservationIgnored private var flatDetector = FlatPhoneDetector()

    @ObservationIgnored private var motionTask: Task<Void, Never>?
    @ObservationIgnored private var scanTasks: [Task<Void, Never>] = []
    /// The MapKit fetch in flight; tests await it.
    @ObservationIgnored private(set) var poiTask: Task<Void, Never>?
    @ObservationIgnored private var announceTask: Task<Void, Never>?

    @ObservationIgnored private var headingEstimator = HeadingEstimator()
    @ObservationIgnored private var locationFix: LocationSample?
    @ObservationIgnored private var mapKitPlaces: [PointToScanPlace] = []
    @ObservationIgnored private var places: [PointToScanPlace] = []
    @ObservationIgnored private var lastPOIOrigin: GeoCoordinate?
    @ObservationIgnored private var poiRetryAfter: Date?

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
        self.now = now
        self.speech = PointToScanSpeechPolicy(clock: clock, now: now)
    }

    isolated deinit {
        motionTask?.cancel()
        scanTasks.forEach { $0.cancel() }
        poiTask?.cancel()
        announceTask?.cancel()
    }

    func setEnabled(_ enabled: Bool) {
        settingEnabled = enabled
        refresh()
    }

    func setHomeVisible(_ visible: Bool) {
        homeVisible = visible
        refresh()
    }

    func setSceneActive(_ active: Bool) {
        sceneActive = active
        refresh()
    }

    /// A sheet over the home screen, which doesn't make it disappear.
    func setHomeCovered(_ covered: Bool) {
        homeCovered = covered
        refresh()
    }

    func toggleMute() {
        scanMuted.toggle()
        refresh()
    }

    private var wantsMotion: Bool {
        settingEnabled && homeVisible && sceneActive && !homeCovered && !scanMuted
    }

    private var mayScan: Bool { wantsMotion && flatDetector.isFlat }

    private var isScanning: Bool { !scanTasks.isEmpty }

    private func refresh() {
        if wantsMotion { startMotion() } else { stopMotion() }
        if mayScan { beginScanning() } else { endScanning() }
    }

    private func startMotion() {
        guard motionTask == nil else { return }
        let samples = motion.gravitySamples()
        motionTask = Task { [weak self] in
            for await sample in samples {
                guard !Task.isCancelled else { return }
                self?.handleGravity(sample)
            }
        }
    }

    private func stopMotion() {
        motionTask?.cancel()
        motionTask = nil
        flatDetector = FlatPhoneDetector()
    }

    private func handleGravity(_ sample: DeviceGravitySample) {
        let wasFlat = flatDetector.isFlat
        guard flatDetector.update(gravityZ: sample.gravityZ) != wasFlat else { return }
        refresh()
    }

    private func beginScanning() {
        guard !isScanning else { return }
        let locations = location.locationSamples()
        let headings = location.headingSamples()
        scanTasks = [
            Task { [weak self] in
                for await sample in locations {
                    guard !Task.isCancelled else { return }
                    self?.handleLocation(sample)
                }
            },
            Task { [weak self] in
                for await sample in headings {
                    guard !Task.isCancelled else { return }
                    self?.handleHeading(sample)
                }
            },
        ]
        places = PointToScanSelection.mergedPlaces(campus: campus, saved: savedPlaces(), mapKit: mapKitPlaces)
        submit(AnnouncementEvent(
            category: .landmark,
            priority: .normal,
            text: Self.startCueText,
            source: .location,
            dedupKey: Self.startCueKey
        ))
    }

    private func endScanning() {
        guard isScanning else { return }
        scanTasks.forEach { $0.cancel() }
        scanTasks = []
        poiTask?.cancel()
        poiTask = nil
        announceTask?.cancel()
        announceTask = nil
        locationFix = nil
        headingEstimator = HeadingEstimator()
        speech.resetScanSession()
    }

    private func handleLocation(_ sample: LocationSample) {
        guard isScanning else { return }
        locationFix = sample
        fetchPOIsIfNeeded(for: sample)
        evaluateSelection()
    }

    private func handleHeading(_ sample: HeadingSample) {
        guard isScanning else { return }
        // Only compass readings, never location fixes: the estimator would otherwise take the walking course,
        // and the scan names what the top of the phone points at.
        headingEstimator.update(with: sample)
        evaluateSelection()
    }

    private func fetchPOIsIfNeeded(for fix: LocationSample) {
        let center = fix.coordinate
        guard poiTask == nil, PointToScanSelection.shouldRefetchPOIs(from: lastPOIOrigin, to: center) else { return }
        if let poiRetryAfter, fix.timestamp < poiRetryAfter { return }
        poiTask = Task { [weak self, poiProvider] in
            let result: Result<[PointToScanPlace], any Error>
            do {
                result = .success(try await poiProvider.fetch(center: center))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.finishPOIFetch(result, for: fix)
        }
    }

    private func finishPOIFetch(_ result: Result<[PointToScanPlace], any Error>, for fix: LocationSample) {
        poiTask = nil
        switch result {
        case .success(let fetched):
            lastPOIOrigin = fix.coordinate
            poiRetryAfter = nil
            mapKitPlaces = fetched
            places = PointToScanSelection.mergedPlaces(campus: campus, saved: savedPlaces(), mapKit: fetched)
            evaluateSelection()
        case .failure(let error):
            if error is CancellationError { return }
            log.error("Nearby places failed to load: \(error.localizedDescription, privacy: .public)")
            poiRetryAfter = fix.timestamp.addingTimeInterval(Self.poiRetryDelay)
        }
    }

    private func evaluateSelection() {
        guard isScanning else { return }
        guard let fix = locationFix, let heading = headingEstimator.heading(at: now()) else {
            speech.update(target: nil, turnedAwayFromLastSpoken: false) { _ in }
            return
        }
        let match = PointToScanSelection.bestMatch(
            origin: fix.coordinate,
            headingDegrees: heading.degrees,
            places: places
        )
        let turnedAway = speech.lastSpokenID
            .flatMap(place(withID:))
            .map { PointToScanSelection.isTurnedAway(origin: fix.coordinate, headingDegrees: heading.degrees, from: $0) }
            ?? false
        speech.update(target: match?.id, turnedAwayFromLastSpoken: turnedAway) { [weak self] placeID in
            self?.announce(placeID: placeID)
        }
    }

    private func place(withID id: String) -> PointToScanPlace? {
        places.first { $0.id == id }
    }

    private func announce(placeID: String) {
        guard isScanning, let origin = locationFix?.coordinate, let place = place(withID: placeID) else { return }
        let metres = GeoMath.distance(from: origin, to: place.coordinate)
        guard metres.isFinite else { return }
        submit(AnnouncementEvent(
            category: .landmark,
            priority: .normal,
            text: "\(place.name), \(distances().words(metres)).",
            distance: metres,
            source: .location,
            dedupKey: "point-to-scan:\(placeID)"
        ))
    }

    /// In order: each waits for the one before.
    private func submit(_ event: AnnouncementEvent) {
        announceTask = Task { [announcements, previous = announceTask] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await announcements.submit(event)
        }
    }
}
