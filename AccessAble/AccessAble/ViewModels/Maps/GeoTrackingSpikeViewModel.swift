#if DEBUG
import ARKit
import CoreLocation
import UIKit

/// AR-1 feasibility spike: runs its own geo-tracking session next to Core Location and logs both once a second, so a
/// campus walk answers whether geo-tracking localizes, how fast, how precisely, and what CV's features keep.
///
/// Owns a separate `ARSession`, so it must not run while CV's camera screen is open.
@MainActor
@Observable
final class GeoTrackingSpikeViewModel: NSObject {
    struct Row: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    enum Mode: String {
        case stopped
        case geo
        /// World tracking like CV runs it, switched to geo-tracking once tracking is normal.
        case switchTest = "switch test"
    }

    // GT spots for the availability check, picked to mix roadside and pedestrian-only paths
    static let spots: [(name: String, coordinate: CLLocationCoordinate2D)] = [
        ("Tech Walkway (pedestrian)", .init(latitude: 33.77490, longitude: -84.39860)),
        ("Tech Green (pedestrian)", .init(latitude: 33.77415, longitude: -84.39745)),
        ("Skiles Walkway (pedestrian)", .init(latitude: 33.77370, longitude: -84.39600)),
        ("Ferst Dr at Atlantic (road)", .init(latitude: 33.77760, longitude: -84.39770)),
        ("North Ave at Techwood (road)", .init(latitude: 33.77110, longitude: -84.39260)),
    ]

    private(set) var mode = Mode.stopped
    private(set) var supportRows: [Row] = []
    private(set) var availabilityRows: [Row] = []
    private(set) var sessionRows: [Row] = []
    private(set) var switchResult = "Not run"
    private(set) var rowCount = 0
    private(set) var logURL: URL?
    var markLabel = ""

    @ObservationIgnored private let session = ARSession()
    @ObservationIgnored private let location = CLLocationManager()
    @ObservationIgnored private var log: FileHandle?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var runStartedAt: Date?
    @ObservationIgnored private var firstLocalizedAt: Date?
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var depthFrameCount = 0
    @ObservationIgnored private var cameraPosition: SIMD3<Float>?
    @ObservationIgnored private var cameraForward: SIMD3<Float>?
    @ObservationIgnored private var cameraTracking = "-"
    @ObservationIgnored private var geoStatus: ARGeoTrackingStatus?
    @ObservationIgnored private var arCoordinate: (CLLocationCoordinate2D, CLLocationDistance)?
    @ObservationIgnored private var clLocation: CLLocation?
    @ObservationIgnored private var clHeading: (trueHeading: Double, headingAccuracy: Double)?
    @ObservationIgnored private var pendingMark: String?
    // switch test: where the camera was just before switching, and when
    @ObservationIgnored private var switchedFrom: (position: SIMD3<Float>, at: Date)?
    @ObservationIgnored private var normalSince: Date?

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.activityType = .otherNavigation
        UIDevice.current.isBatteryMonitoringEnabled = true
        supportRows = Self.supportChecks()
    }

    func checkAvailability() async {
        availabilityRows = []
        var rows: [Row] = []
        for spot in Self.spots {
            rows.append(Row(label: spot.name, value: await Self.availability(at: spot.coordinate)))
        }
        rows.append(Row(label: "Here (current location)", value: await Self.availabilityHere()))
        availabilityRows = rows
        writeLine("# availability " + rows.map { "\($0.label)=\($0.value)" }.joined(separator: "; "))
    }

    func start(_ newMode: Mode) {
        stop()
        guard newMode != .stopped else { return }
        mode = newMode
        openLog()
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        location.startUpdatingLocation()
        location.startUpdatingHeading()

        session.delegate = self
        session.delegateQueue = .main
        runStartedAt = .now
        firstLocalizedAt = nil
        switchedFrom = nil
        normalSince = nil
        switchResult = newMode == .switchTest ? "Waiting for normal world tracking…" : switchResult
        session.run(newMode == .geo ? Self.geoConfiguration() : Self.worldConfiguration(),
                    options: [.resetTracking, .removeExistingAnchors])

        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        session.pause()
        location.stopUpdatingLocation()
        location.stopUpdatingHeading()
        try? log?.close()
        log = nil
        mode = .stopped
    }

    func mark() {
        let label = markLabel.trimmingCharacters(in: .whitespaces)
        pendingMark = label.isEmpty ? "mark" : label
        markLabel = ""
    }

    // MARK: - Once a second

    private func tick() {
        let now = Date.now
        let fps = frameCount
        let depthShare = frameCount > 0 ? Double(depthFrameCount) / Double(frameCount) : 0
        frameCount = 0
        depthFrameCount = 0

        if let position = cameraPosition, geoStatus?.state == .localized {
            session.getGeoLocation(forPoint: position) { [weak self] coordinate, altitude, error in
                guard error == nil else { return }
                Task { @MainActor in self?.arCoordinate = (coordinate, altitude) }
            }
        } else {
            arCoordinate = nil
        }

        let state = geoStatus.map { Self.describe($0.state) } ?? "-"
        let reason = geoStatus.map { Self.describe($0.stateReason) } ?? "-"
        let accuracy = geoStatus.map { Self.describe($0.accuracy) } ?? "-"
        let localizeTime = zip(runStartedAt, firstLocalizedAt).map { String(format: "%.1f s", $1.timeIntervalSince($0)) }
        let arHeading = geoStatus?.state == .localized ? cameraForward.map(Self.heading(of:)) : nil
        let compass = clHeading.flatMap { $0.headingAccuracy >= 0 && $0.trueHeading >= 0 ? $0 : nil }
        let gap: Double? = zip(arCoordinate, clLocation).map { ar, cl in
            CLLocation(latitude: ar.0.latitude, longitude: ar.0.longitude).distance(from: cl)
        }
        let headingGap = zip(arHeading, compass).map { abs(Self.wrap($0 - $1.trueHeading)) }

        sessionRows = [
            Row(label: "Mode", value: mode.rawValue),
            Row(label: "Geo state", value: state),
            Row(label: "Geo reason", value: reason),
            Row(label: "Geo accuracy", value: accuracy),
            Row(label: "Time to localize", value: localizeTime ?? "not yet"),
            Row(label: "Camera tracking", value: cameraTracking),
            Row(label: "Frames per second", value: "\(fps)"),
            Row(label: "Frames with LiDAR depth", value: String(format: "%.0f%%", depthShare * 100)),
            Row(label: "AR position", value: arCoordinate.map { Self.format($0.0) } ?? "-"),
            Row(label: "GPS position", value: clLocation.map {
                Self.format($0.coordinate) + String(format: " ±%.0f m", $0.horizontalAccuracy)
            } ?? "-"),
            Row(label: "AR to GPS", value: gap.map { String(format: "%.1f m", $0) } ?? "-"),
            Row(label: "AR heading", value: arHeading.map { String(format: "%.0f°", $0) } ?? "-"),
            Row(label: "Compass heading", value: compass.map {
                String(format: "%.0f° ±%.0f°", $0.trueHeading, $0.headingAccuracy)
            } ?? "-"),
            Row(label: "AR to compass", value: headingGap.map { String(format: "%.0f°", $0) } ?? "-"),
            Row(label: "Thermal state", value: Self.describe(ProcessInfo.processInfo.thermalState)),
            Row(label: "Battery", value: String(format: "%.0f%%", UIDevice.current.batteryLevel * 100)),
        ]

        let mark = pendingMark ?? ""
        pendingMark = nil
        let fields: [String] = [
            ISO8601DateFormatter().string(from: now), mode.rawValue, state, reason, accuracy, cameraTracking,
            "\(fps)", String(format: "%.2f", depthShare),
            arCoordinate.map { String(format: "%.7f", $0.0.latitude) } ?? "",
            arCoordinate.map { String(format: "%.7f", $0.0.longitude) } ?? "",
            arCoordinate.map { String(format: "%.1f", $0.1) } ?? "",
            clLocation.map { String(format: "%.7f", $0.coordinate.latitude) } ?? "",
            clLocation.map { String(format: "%.7f", $0.coordinate.longitude) } ?? "",
            clLocation.map { String(format: "%.1f", $0.horizontalAccuracy) } ?? "",
            gap.map { String(format: "%.1f", $0) } ?? "",
            arHeading.map { String(format: "%.0f", $0) } ?? "",
            compass.map { String(format: "%.0f", $0.trueHeading) } ?? "",
            compass.map { String(format: "%.0f", $0.headingAccuracy) } ?? "",
            "\(ProcessInfo.processInfo.thermalState.rawValue)", String(format: "%.2f", UIDevice.current.batteryLevel),
            mark.replacingOccurrences(of: ",", with: " "),
        ]
        writeLine(fields.joined(separator: ","))
        rowCount += 1
    }

    // MARK: - Configurations

    private static func geoConfiguration() -> ARGeoTrackingConfiguration {
        let configuration = ARGeoTrackingConfiguration()
        if ARGeoTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        return configuration
    }

    // matches ARSessionManager.start()
    private static func worldConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        return configuration
    }

    private static func supportChecks() -> [Row] {
        let geo = ARGeoTrackingConfiguration.self
        let world = ARWorldTrackingConfiguration.self
        // ARGeoTrackingConfiguration has no sceneReconstruction in its API; this confirms it at runtime
        let geoHasMesh = ARGeoTrackingConfiguration().responds(to: NSSelectorFromString("setSceneReconstruction:"))
        return [
            Row(label: "Geo-tracking supported", value: yesNo(geo.isSupported)),
            Row(label: "Geo: LiDAR depth", value: yesNo(geo.supportsFrameSemantics(.sceneDepth))),
            Row(label: "Geo: smoothed depth", value: yesNo(geo.supportsFrameSemantics(.smoothedSceneDepth))),
            Row(label: "Geo: people occlusion", value: yesNo(geo.supportsFrameSemantics(.personSegmentationWithDepth))),
            Row(label: "Geo: classified mesh", value: yesNo(geoHasMesh)),
            Row(label: "World: LiDAR depth", value: yesNo(world.supportsFrameSemantics(.sceneDepth))),
            Row(label: "World: classified mesh", value: yesNo(world.supportsSceneReconstruction(.meshWithClassification))),
        ]
    }

    // MARK: - Availability

    private nonisolated static func availability(at coordinate: CLLocationCoordinate2D) async -> String {
        await withCheckedContinuation { continuation in
            ARGeoTrackingConfiguration.checkAvailability(at: coordinate) { @Sendable available, error in
                continuation.resume(returning: describeAvailability(available, error))
            }
        }
    }

    private nonisolated static func availabilityHere() async -> String {
        await withCheckedContinuation { continuation in
            ARGeoTrackingConfiguration.checkAvailability { @Sendable available, error in
                continuation.resume(returning: describeAvailability(available, error))
            }
        }
    }

    private nonisolated static func describeAvailability(_ available: Bool, _ error: (any Error)?) -> String {
        if available { return "available" }
        return error.map { "no: \($0.localizedDescription)" } ?? "no"
    }

    // MARK: - Log file

    private func openLog() {
        let name = "geo-spike-\(ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")).csv"
        let url = URL.documentsDirectory.appending(path: name)
        FileManager.default.createFile(atPath: url.path(), contents: nil)
        log = try? FileHandle(forWritingTo: url)
        logURL = url
        rowCount = 0
        writeLine("# " + supportRows.map { "\($0.label)=\($0.value)" }.joined(separator: "; "))
        writeLine("time,mode,geo_state,geo_reason,geo_accuracy,camera_tracking,fps,depth_share,ar_lat,ar_lon,ar_alt,"
            + "gps_lat,gps_lon,gps_accuracy_m,ar_gps_gap_m,ar_heading,compass_heading,compass_accuracy,thermal,battery,mark")
    }

    private func writeLine(_ line: String) {
        log?.write(Data((line + "\n").utf8))
    }

    // MARK: - Formatting

    /// Degrees clockwise from true north of the camera's view. Geo-tracking's world is east-up-south, so north is -z.
    private static func heading(of forward: SIMD3<Float>) -> Double {
        let degrees = atan2(Double(forward.x), Double(-forward.z)) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Into -180..<180.
    private static func wrap(_ degrees: Double) -> Double {
        let wrapped = (degrees + 180).truncatingRemainder(dividingBy: 360)
        return (wrapped < 0 ? wrapped + 360 : wrapped) - 180
    }

    private static func format(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    private static func describe(_ state: ARGeoTrackingStatus.State) -> String {
        switch state {
        case .notAvailable: "not available"
        case .initializing: "initializing"
        case .localizing: "localizing"
        case .localized: "localized"
        @unknown default: "unknown"
        }
    }

    private static func describe(_ reason: ARGeoTrackingStatus.StateReason) -> String {
        switch reason {
        case .none: "none"
        case .notAvailableAtLocation: "not available here"
        case .needLocationPermissions: "needs location permission"
        case .worldTrackingUnstable: "world tracking unstable"
        case .waitingForLocation: "waiting for location"
        case .waitingForAvailabilityCheck: "checking availability"
        case .geoDataNotLoaded: "map data not loaded"
        case .devicePointedTooLow: "pointed too low"
        case .visualLocalizationFailed: "visual localization failed"
        @unknown default: "unknown"
        }
    }

    private static func describe(_ accuracy: ARGeoTrackingStatus.Accuracy) -> String {
        switch accuracy {
        case .undetermined: "undetermined"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        @unknown default: "unknown"
        }
    }

    private static func describe(_ tracking: ARCamera.TrackingState) -> String {
        switch tracking {
        case .normal: "normal"
        case .notAvailable: "not available"
        case .limited(.initializing): "limited: initializing"
        case .limited(.excessiveMotion): "limited: moving too fast"
        case .limited(.insufficientFeatures): "limited: not enough detail"
        case .limited(.relocalizing): "limited: relocalizing"
        case .limited: "limited"
        }
    }

    private static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

// MARK: - Delegates (delivered on the main queue)

extension GeoTrackingSpikeViewModel: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let transform = frame.camera.transform
        let tracking = frame.camera.trackingState
        let hasDepth = frame.sceneDepth != nil
        let status = frame.geoTrackingStatus
        MainActor.assumeIsolated {
            frameCount += 1
            if hasDepth { depthFrameCount += 1 }
            let position = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            cameraPosition = position
            cameraForward = -SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            cameraTracking = Self.describe(tracking)
            geoStatus = status
            if status?.state == .localized, firstLocalizedAt == nil { firstLocalizedAt = .now }
            if mode == .switchTest { advanceSwitchTest(position: position, tracking: tracking) }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: any Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            sessionRows.insert(Row(label: "Session failed", value: message), at: 0)
            writeLine("# session failed: \(message)")
        }
    }

    private func advanceSwitchTest(position: SIMD3<Float>, tracking: ARCamera.TrackingState) {
        if let switchedFrom {
            // judged one second after the switch: a reset puts the camera back near the origin or re-initializes
            let elapsed = Date.now.timeIntervalSince(switchedFrom.at)
            guard elapsed >= 1, switchResult.hasPrefix("Switched") else { return }
            let jump = simd_distance(position, switchedFrom.position)
            let kept = jump < 0.5 && tracking == .normal
            switchResult = String(format: "%@: camera moved %.2f m across the switch, tracking %@",
                                  kept ? "World kept" : "World reset", jump, Self.describe(tracking))
            writeLine("# switch test: \(switchResult)")
            return
        }
        guard tracking == .normal else { normalSince = nil; return }
        normalSince = normalSince ?? .now
        // a few seconds of normal tracking first, so the world CV would have built exists
        guard let normalSince, Date.now.timeIntervalSince(normalSince) >= 3 else { return }
        switchedFrom = (position, .now)
        switchResult = "Switched to geo-tracking, checking…"
        session.run(Self.geoConfiguration(), options: [])
        writeLine("# switch test: switched world to geo without reset")
    }
}

extension GeoTrackingSpikeViewModel: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        MainActor.assumeIsolated { clLocation = latest }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // CLHeading isn't Sendable, so only its numbers cross over
        let reading = (trueHeading: newHeading.trueHeading, headingAccuracy: newHeading.headingAccuracy)
        MainActor.assumeIsolated { clHeading = reading }
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
#endif
