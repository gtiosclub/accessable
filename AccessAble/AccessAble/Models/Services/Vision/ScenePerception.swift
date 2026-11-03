import ARKit
import Foundation
import Synchronization
import UIKit
import QuartzCore
import os
import simd

/// Owner: Computer Vision (1.1, 1.4). Turns one `ARFrame` into a `SceneObservation` and
/// the obstacle announcements it calls for.
///
/// `capturedImage` goes to Vision for people (T14) and objects (T13). `sceneDepth` becomes
/// one filtered `DepthMap` (T6) that places those detections in the world (T5, T7) and is
/// unprojected into a point cloud for the floor fit (T10), geometric obstacles (T11) and
/// the ground profile behind kerb detection (T12). The floor is remembered between frames
/// (`FloorMemory`), so obstacles are still measured when no floor is in view — up against
/// a wall, say. Every obstacle's footprint feeds the clearance search (`assessPath`) that
/// says which way round is open. Obstacles that match a recognized object take its label,
/// every detection gets a stable track ID (T15), and the announcer (T16) decides what the
/// user should hear about the walking corridor (T9). Text (T17) is read on the side by
/// `TextReader` and attached as it becomes available.
///
/// Call `analyze` from one queue at a time — `ARSceneAnalyzer` calls it from its
/// latest-only processing queue. State that outlives a frame, or that the UI reads, lives
/// behind a `Mutex`.
final class ScenePerception: Sendable {
    struct Analysis: Sendable {
        let observation: SceneObservation
        let announcements: [AnnouncementEvent]
        /// `Detection.id`s of the detections inside the walking corridor this frame.
        let inPath: Set<UUID>
        /// Time spent in `analyze`, in milliseconds.
        let processingMilliseconds: Double
        /// Whether an OCR read was running while this frame was analyzed.
        let wasReadingText: Bool
    }

    /// What the live debug screen shows besides the observation itself.
    struct Diagnostics: Sendable {
        var floor: Plane3D?
        /// Signed height of the camera above the fitted floor, in metres. A good live
        /// sanity check on T10: held normally it should read roughly 1.1 to 1.5 m.
        var cameraHeight: Float?
        /// False when `floor` is remembered or assumed rather than fitted to this frame.
        var isFloorMeasured = false
        /// Where the open space is, when depth could tell.
        var path: PathAssessment?
        /// What "take me to…" is doing, while a request is active or just finished.
        var navigation: NavigationStatus?
        /// width / height of the frame once rotated upright. Overlays need it to map a
        /// normalized box onto an aspect-filled preview.
        var uprightAspectRatio: Float = 3.0 / 4.0
        /// Analysis rate and latency over the last few seconds (T20).
        var performance: PerformanceMetrics?
    }

    private let peopleDetector: PeopleDetector
    private let objectDetector: ObjectDetector?
    private let textReader: TextReader
    private let corridorWidth: Float
    private let corridorDistance: Float
    private let log = Logger(subsystem: "AccessAble", category: "ScenePerception")

    private let diagnosticsState = Mutex(Diagnostics())
    private let floorMemory = Mutex(FloorMemory())
    private let tracker = Mutex(ObjectTracker())
    private let announcer = Mutex(ObstacleAnnouncer())
    private let frameTimer = Mutex(FrameTimer())
    private let occupancy = Mutex(LocalOccupancyMap())
    private let navigation = Mutex<NavigationGuide?>(nil)
    /// When the announcer last spoke about the path, so navigation cues keep out of its way.
    private let lastPathAnnouncement = Mutex<TimeInterval>(-.infinity)
    private let crosswalkConfirmer = Mutex(CrosswalkConfirmer())
    private let streetSignals = Mutex(StreetSignalAnnouncer())
    /// Set when a request arrives, consumed by the next frame, which knows the frame time.
    private let pendingNavigationQuery = Mutex<String??>(nil)
    private let clearanceTuning = PathClearanceTuning.default

    init(
        peopleDetector: PeopleDetector = PeopleDetector(),
        objectDetector: ObjectDetector? = ObjectDetector(),
        textReader: TextReader = TextReader(),
        corridorWidth: Float = WalkingCorridor.default.width,
        corridorDistance: Float = WalkingCorridor.default.maxDistance
    ) {
        self.peopleDetector = peopleDetector
        self.objectDetector = objectDetector
        self.textReader = textReader
        self.corridorWidth = corridorWidth
        self.corridorDistance = corridorDistance
    }

    var diagnostics: Diagnostics { diagnosticsState.withLock { $0 } }

    /// Forgets everything carried between frames. Call when tracking restarts: world
    /// coordinates change, so the remembered floor and the announcement state are void.
    func reset() {
        floorMemory.withLock { $0.reset() }
        tracker.withLock { $0 = ObjectTracker() }
        announcer.withLock { $0 = ObstacleAnnouncer() }
        navigation.withLock { $0 = nil }
        pendingNavigationQuery.withLock { $0 = nil }
        occupancy.withLock { $0.reset() }
        lastPathAnnouncement.withLock { $0 = -.infinity }
        crosswalkConfirmer.withLock { $0 = CrosswalkConfirmer() }
        streetSignals.withLock { $0 = StreetSignalAnnouncer() }
    }

    /// Starts steering the user towards `query` ("the chair", "exit"), replacing any
    /// current request; nil cancels. Takes effect on the next analyzed frame.
    func navigate(to query: String?) {
        pendingNavigationQuery.withLock { $0 = .some(query) }
    }

    /// The current "take me to…" status, if any.
    var navigationStatus: NavigationStatus? { diagnostics.navigation }

    func analyze(_ frame: ARFrame, interfaceOrientation: UIInterfaceOrientation) -> Analysis {
        let start = CACurrentMediaTime()
        let imageOrientation = CGImagePropertyOrientation(cameraImageIn: interfaceOrientation)
        let upright = uprightSize(for: frame.camera.imageResolution, orientation: interfaceOrientation)
        var diagnostics = Diagnostics(uprightAspectRatio: Float(upright.width / upright.height))

        let depthMap = frame.sceneDepth.flatMap { DepthMap(depth: $0.depthMap, confidence: $0.confidenceMap) }
        let cameraTransform = frame.camera.transform
        // Text is read later, on its own queue; give it this frame's depth so each sign
        // gets a world position that matches the frame it was read from.
        let textLocator: TextReader.Locator? = depthMap.map { depthMap in
            let intrinsics = depthIntrinsics(for: frame.camera, depth: depthMap)
            return { box in
                worldPosition(
                    ofRegion: imageOrientation.sensorRect(fromUpright: box), in: depthMap,
                    intrinsics: intrinsics, cameraTransform: cameraTransform
                )
            }
        }
        textReader.readIfDue(frame.capturedImage, orientation: imageOrientation, at: frame.timestamp, locate: textLocator)
        let wasReadingText = textReader.isReading
        var recognized = recognizeObjects(in: frame.capturedImage, orientation: imageOrientation)
        // T37: crosswalk stripes. Skipped when the phone points up and there's no ground in view.
        let lookingUp = -frame.camera.transform.columns.2.y > 0.3
        let stripes = lookingUp ? nil : uprightLumaGrid(
            from: frame.capturedImage, orientation: imageOrientation,
            width: 96, height: max(Int(96 * upright.height / upright.width), 1)
        ).flatMap { detectCrosswalk(in: $0) }
        let crosswalkBox = crosswalkConfirmer.withLock { $0.update(stripes) }
        var obstacles: [Detection] = []
        var hazards: [ElevationHazard] = []
        var path: PathAssessment?
        var blockedAhead: BlockedAhead?
        // `Detection.id`s of everything inside the walking corridor this frame.
        var inPath = Set<UUID>()

        let corridor = corridor(for: frame.camera)
        // World space is gravity-aligned, so flattening onto world up gives a level
        // heading for bearings and the path test even before a floor has been found.
        let heading = corridor.flattened(ontoFloorNormal: [0, 1, 0]) ?? corridor

        if let depthMap {
            let camera = frame.camera
            let intrinsics = depthIntrinsics(for: camera, depth: depthMap)

            // T5 + T7 — distance and direction for each recognized object.
            recognized = recognized.map { detection in
                let region = imageOrientation.sensorRect(fromUpright: detection.boundingBox)
                guard let position = worldPosition(
                    ofRegion: region, in: depthMap, intrinsics: intrinsics, cameraTransform: camera.transform
                ) else { return detection }
                var located = detection
                located.distance = Double(heading.distance(to: position))
                located.bearing = heading.bearing(to: position)
                located.worldPosition = position
                // Only things a walker can collide with are path hazards; a recognized cup
                // on a table is left to the geometry to judge.
                if heading.contains(position), detection.isHazard || detection.label == "person" {
                    inPath.insert(detection.id)
                }
                return located
            }

            let cloud = unprojectDepthMap(depthMap, intrinsics: intrinsics, cameraTransform: camera.transform)

            // T10 — the floor everything else is measured against. When none is in view
            // (close to a wall, the floor leaves the frame) the remembered one stands in.
            let floor = floorMemory.withLock {
                $0.update(fit: detectFloorPlane(points: cloud), cameraPosition: corridor.origin, at: frame.timestamp)
            }
            diagnostics.floor = floor.plane
            diagnostics.cameraHeight = floor.cameraHeight
            diagnostics.isFloorMeasured = floor.isMeasured

            // T11 — obstacles by geometry, no labels needed. Against a remembered floor
            // the tolerance is looser: the real floor may sit a few centimetres off it,
            // and must not become a knee-high obstacle.
            var obstacleTuning = ObstacleDetectionTuning.default
            if !floor.isMeasured { obstacleTuning.floorTolerance = 0.15 }
            let found = detectObstacles(points: cloud, floor: floor.plane, corridor: corridor, tuning: obstacleTuning)

            // The map remembers what has been seen; the plan reads the map, not the frame.
            let plan = occupancy.withLock { map in
                map.integrate(points: cloud, floor: floor.plane, cameraPosition: corridor.origin, floorIsMeasured: floor.isMeasured)
                return planPath(map: map, heading: heading, tuning: clearanceTuning)
            }
            path = plan
            blockedAhead = BlockedAhead(distance: plan.blockedDistance)
            diagnostics.path = plan

            // What the sensor could see sideways at each distance, for naming walls.
            let coverage = coverageProfile(points: cloud, floor: floor.plane, corridor: corridor, lookAhead: clearanceTuning.lookAhead)

            obstacles = found
                .filter(\.intersectsWalkingCorridor)
                .compactMap {
                    detection(
                        for: $0, floor: floor.plane, coverage: coverage?.lateral(at: $0.forwardRange.lowerBound),
                        heading: heading, camera: camera, orientation: interfaceOrientation, viewportSize: upright
                    )
                }
            inPath.formUnion(obstacles.map(\.id))

            // T12 — kerbs and drop-offs in the surface itself. Only against a floor fitted
            // to this frame: a few centimetres of error in a remembered floor is a kerb.
            // Obstacles are cut out of the profile so a chair leg is not a step.
            if floor.isMeasured {
                let profile = groundProfile(points: cloud, floor: floor.plane, corridor: corridor, excluding: found)
                hazards = detectElevationHazards(samples: profile)
            }
        }

        let detections = tracker.withLock {
            $0.update(fuse(obstacles: obstacles, recognized: recognized), at: frame.timestamp)
        }
        var observed = detections
        if let crosswalkBox {
            observed.append(Detection(label: "crosswalk", confidence: 1, boundingBox: crosswalkBox, origin: .model, isHazard: false))
        }
        let recognizedText = textReader.currentText(at: frame.timestamp)
        var announcements = announcer.withLock {
            $0.announcements(
                for: detections.map { ObstacleAlertInput(detection: $0, isInPath: inPath.contains($0.id)) },
                hazards: hazards,
                path: path,
                blockedAhead: blockedAhead,
                at: frame.timestamp
            )
        }
        if !announcements.isEmpty {
            lastPathAnnouncement.withLock { $0 = frame.timestamp }
        }
        announcements += streetSignals.withLock { $0.announcements(for: observed, at: frame.timestamp) }

        // "Take me to…": sightings go in, one instruction at a time comes out.
        if let pending = pendingNavigationQuery.withLock({ query in
            defer { query = nil }
            return query
        }) {
            navigation.withLock { $0 = pending.map { NavigationGuide(query: $0, at: frame.timestamp) } }
        }
        // Navigation cues hold back for a moment after a path warning; the warning matters more.
        let pathSpokeRecently = frame.timestamp - lastPathAnnouncement.withLock { $0 } < 2.5
        diagnostics.navigation = navigation.withLock { guide -> NavigationStatus? in
            guard guide != nil else { return nil }
            let result = guide!.update(detections: detections, text: recognizedText, heading: heading, at: frame.timestamp)
            if let event = result.announcement, !pathSpokeRecently || event.priority >= .high {
                announcements.append(event)
            }
            return result.status
        }
        let end = CACurrentMediaTime()
        diagnostics.performance = frameTimer.withLock { timer in
            timer.record(start: start, end: end)
            return timer.metrics
        }
        diagnosticsState.withLock { $0 = diagnostics }

        let observation = SceneObservation(
            timestamp: .now,
            detections: observed,
            ground: groundSurface(for: hazards),
            recognizedText: recognizedText,
            elevationHazards: hazards,
            hasMetricDepth: depthMap != nil
        )
        return Analysis(
            observation: observation,
            announcements: announcements,
            inPath: inPath,
            processingMilliseconds: (end - start) * 1000,
            wasReadingText: wasReadingText || textReader.isReading
        )
    }
}

// MARK: - Helpers

private extension ScenePerception {
    /// People (T14) and everything else the object model knows (T13), in upright coordinates.
    func recognizeObjects(in image: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> [Detection] {
        var detections: [Detection] = []
        do {
            detections += try peopleDetector.detect(pixelBuffer: image, orientation: orientation)
        } catch {
            log.error("people detection failed: \(error.localizedDescription, privacy: .public)")
        }
        guard let objectDetector else { return detections }
        do {
            detections += try objectDetector.detect(pixelBuffer: image, orientation: orientation)
        } catch {
            log.error("object detection failed: \(error.localizedDescription, privacy: .public)")
        }
        return detections
    }

    /// The corridor straight ahead of the camera. The detectors re-orthogonalize these
    /// axes onto the floor plane themselves, so passing the raw camera axes is fine.
    func corridor(for camera: ARCamera) -> WalkingCorridor {
        let transform = camera.transform
        let position = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        // A camera looks along its own -Z.
        let forward = -SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        let right = SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)

        return WalkingCorridor(
            origin: position,
            forward: forward,
            right: right,
            width: corridorWidth,
            maxDistance: corridorDistance
        )
    }

    /// ARKit's intrinsics describe the captured image, which is far larger than the depth
    /// map. Using them unscaled gives a point cloud that looks plausible and is quietly wrong.
    func depthIntrinsics(for camera: ARCamera, depth: DepthMap) -> CameraIntrinsics {
        CameraIntrinsics(
            focalX: camera.intrinsics[0][0],
            focalY: camera.intrinsics[1][1],
            principalX: camera.intrinsics[2][0],
            principalY: camera.intrinsics[2][1],
            imageWidth: Int(camera.imageResolution.width),
            imageHeight: Int(camera.imageResolution.height)
        ).scaled(toWidth: depth.width, height: depth.height)
    }

    /// Wraps a geometric obstacle as a `Detection`, named by its shape ("wall", "pole"…)
    /// and projected back into normalized image space so the UI can draw a box around it.
    func detection(
        for obstacle: GeometricObstacle,
        floor: Plane3D,
        coverage: ClosedRange<Float>?,
        heading: WalkingCorridor,
        camera: ARCamera,
        orientation: UIInterfaceOrientation,
        viewportSize: CGSize
    ) -> Detection? {
        guard let box = projectedBoundingBox(
            obstacle: obstacle, floor: floor, corridor: heading,
            camera: camera, orientation: orientation, viewportSize: viewportSize
        ) else { return nil }

        return Detection(
            label: obstacle.kind(coverage: coverage).label,
            confidence: 1,
            boundingBox: box,
            distance: Double(obstacle.nearestDistance),
            bearing: heading.bearing(to: obstacle.center),
            origin: .geometric,
            isHazard: true,
            worldPosition: obstacle.center
        )
    }

    func projectedBoundingBox(
        obstacle: GeometricObstacle,
        floor: Plane3D,
        corridor: WalkingCorridor,
        camera: ARCamera,
        orientation: UIInterfaceOrientation,
        viewportSize: CGSize
    ) -> CGRect? {
        let up = floor.normal
        let right = corridor.right
        let forward = corridor.forward
        let halfWidth = max(obstacle.width, 0.05) / 2
        // The obstacle's footprint depth isn't measured, so reuse its width for it.
        let halfDepth = halfWidth
        // `center` is the cluster centroid and `height` is the top above the floor, so
        // span from the floor up to the top rather than symmetrically about the centroid.
        let base = obstacle.center - up * distanceFromPlane(point: obstacle.center, plane: floor)

        var minPoint = CGPoint(x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude)
        var maxPoint = CGPoint(x: -CGFloat.greatestFiniteMagnitude, y: -CGFloat.greatestFiniteMagnitude)
        var projectedAny = false

        for dx in [-halfWidth, halfWidth] {
            for dz in [-halfDepth, halfDepth] {
                for dy in [Float(0), obstacle.height] {
                    let corner = base + right * dx + forward * dz + up * dy
                    // Points behind the camera project to nonsense.
                    guard simd_dot(corner - corridor.origin, forward) > 0.05 else { continue }

                    let projected = camera.projectPoint(
                        corner, orientation: orientation, viewportSize: viewportSize
                    )
                    guard projected.x.isFinite, projected.y.isFinite else { continue }
                    projectedAny = true
                    minPoint.x = min(minPoint.x, projected.x)
                    minPoint.y = min(minPoint.y, projected.y)
                    maxPoint.x = max(maxPoint.x, projected.x)
                    maxPoint.y = max(maxPoint.y, projected.y)
                }
            }
        }
        guard projectedAny, viewportSize.width > 0, viewportSize.height > 0 else { return nil }

        func clamp(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }
        let x0 = clamp(minPoint.x / viewportSize.width)
        let x1 = clamp(maxPoint.x / viewportSize.width)
        let y0 = clamp(minPoint.y / viewportSize.height)
        let y1 = clamp(maxPoint.y / viewportSize.height)
        guard x1 > x0, y1 > y0 else { return nil }

        // projectPoint already returns upright, origin-top-left viewport coordinates,
        // which is exactly what `Detection.boundingBox` is documented to hold.
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func groundSurface(for hazards: [ElevationHazard]) -> GroundSurface {
        if hazards.contains(where: { $0.type == .dropOff }) { return .dropOff }
        if hazards.count(where: { $0.type == .stepUp || $0.type == .stepDown }) >= 3 { return .stairs }
        return .unknown
    }

    /// Captured-image size rotated into the orientation the UI is showing.
    func uprightSize(for resolution: CGSize, orientation: UIInterfaceOrientation) -> CGSize {
        switch orientation {
        case .landscapeLeft, .landscapeRight: resolution
        default: CGSize(width: resolution.height, height: resolution.width)
        }
    }
}
