import ARKit
import Foundation
import Synchronization
import UIKit
import os
import simd

/// Owner: Computer Vision (1.1, 1.4). Turns one `ARFrame` into a `SceneObservation` and
/// the obstacle announcements it calls for.
///
/// `capturedImage` goes to Vision for people (T14) and objects (T13). `sceneDepth` becomes
/// one filtered `DepthMap` (T6) that places those detections in the world (T5, T7) and is
/// unprojected into a point cloud for the floor fit (T10), geometric obstacles (T11) and
/// the ground profile behind kerb detection (T12). Obstacles that match a recognized object
/// take its label, every detection gets a stable track ID (T15), and the announcer (T16)
/// decides what in the walking corridor (T9) the user should hear about. Text (T17) is
/// read on the side by `TextReader` and attached as it becomes available.
///
/// Call `analyze` from one queue at a time — `ARSceneAnalyzer` calls it from its
/// latest-only processing queue. State that outlives a frame, or that the UI reads, lives
/// behind a `Mutex`.
final class ScenePerception: Sendable {
    struct Analysis: Sendable {
        let observation: SceneObservation
        let announcements: [AnnouncementEvent]
    }

    /// What the live debug screen shows besides the observation itself.
    struct Diagnostics: Sendable {
        var floor: Plane3D?
        /// Signed height of the camera above the fitted floor, in metres. A good live
        /// sanity check on T10: held normally it should read roughly 1.1 to 1.5 m.
        var cameraHeight: Float?
        /// width / height of the frame once rotated upright. Overlays need it to map a
        /// normalized box onto an aspect-filled preview.
        var uprightAspectRatio: Float = 3.0 / 4.0
    }

    private let peopleDetector: PeopleDetector
    private let objectDetector: ObjectDetector?
    private let textReader: TextReader
    private let corridorWidth: Float
    private let corridorDistance: Float
    private let log = Logger(subsystem: "AccessAble", category: "ScenePerception")

    private let diagnosticsState = Mutex(Diagnostics())
    private let tracker = Mutex(ObjectTracker())
    private let announcer = Mutex(ObstacleAnnouncer())

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

    func analyze(_ frame: ARFrame, interfaceOrientation: UIInterfaceOrientation) -> Analysis {
        let imageOrientation = CGImagePropertyOrientation(cameraImageIn: interfaceOrientation)
        let upright = uprightSize(for: frame.camera.imageResolution, orientation: interfaceOrientation)
        var diagnostics = Diagnostics(uprightAspectRatio: Float(upright.width / upright.height))

        textReader.readIfDue(frame.capturedImage, orientation: imageOrientation, at: frame.timestamp)
        var recognized = recognizeObjects(in: frame.capturedImage, orientation: imageOrientation)
        var obstacles: [Detection] = []
        var hazards: [ElevationHazard] = []
        /// `Detection.id`s of everything inside the walking corridor this frame.
        var inPath = Set<UUID>()
        let depthMap = frame.sceneDepth.flatMap { DepthMap(depth: $0.depthMap, confidence: $0.confidenceMap) }

        if let depthMap {
            let camera = frame.camera
            let intrinsics = depthIntrinsics(for: camera, depth: depthMap)
            let corridor = corridor(for: camera)
            // World space is gravity-aligned, so flattening onto world up gives a level
            // heading for bearings and the path test even before a floor has been found.
            let heading = corridor.flattened(ontoFloorNormal: [0, 1, 0]) ?? corridor

            // T5 + T7 — distance and direction for each recognized object.
            recognized = recognized.map { detection in
                let region = imageOrientation.sensorRect(fromUpright: detection.boundingBox)
                guard let position = worldPosition(
                    ofRegion: region, in: depthMap, intrinsics: intrinsics, cameraTransform: camera.transform
                ) else { return detection }
                var located = detection
                located.distance = Double(heading.distance(to: position))
                located.bearing = heading.bearing(to: position)
                // Only things a walker can collide with are path hazards; a recognized cup
                // on a table is left to the geometry to judge.
                if heading.contains(position), detection.isHazard || detection.label == "person" {
                    inPath.insert(detection.id)
                }
                return located
            }

            let cloud = unprojectDepthMap(depthMap, intrinsics: intrinsics, cameraTransform: camera.transform)

            // T10 — the floor everything else is measured against.
            if let fit = detectFloorPlane(points: cloud) {
                diagnostics.floor = fit.plane
                diagnostics.cameraHeight = distanceFromPlane(point: corridor.origin, plane: fit.plane)

                // T11 — obstacles by geometry, no labels needed.
                obstacles = detectObstacles(points: cloud, floor: fit.plane, corridor: corridor)
                    .filter(\.intersectsWalkingCorridor)
                    .compactMap {
                        detection(
                            for: $0, floor: fit.plane, heading: heading,
                            camera: camera, orientation: interfaceOrientation, viewportSize: upright
                        )
                    }
                inPath.formUnion(obstacles.map(\.id))

                // T12 — kerbs and drop-offs in the surface itself.
                let profile = groundProfile(points: cloud, floor: fit.plane, corridor: corridor)
                hazards = detectElevationHazards(samples: profile)
            }
        }

        let detections = tracker.withLock {
            $0.update(fuse(obstacles: obstacles, recognized: recognized), at: frame.timestamp)
        }
        let announcements = announcer.withLock {
            $0.announcements(
                for: detections.map { ObstacleAlertInput(detection: $0, isInPath: inPath.contains($0.id)) },
                hazards: hazards,
                at: frame.timestamp
            )
        }
        diagnosticsState.withLock { $0 = diagnostics }

        let observation = SceneObservation(
            timestamp: .now,
            detections: detections,
            ground: groundSurface(for: hazards),
            recognizedText: textReader.currentText(at: frame.timestamp),
            elevationHazards: hazards,
            hasMetricDepth: depthMap != nil
        )
        return Analysis(observation: observation, announcements: announcements)
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

    /// Wraps a geometric obstacle as a `Detection`, projecting its 3D extent back into
    /// normalized image space so the UI can draw a box around it.
    func detection(
        for obstacle: GeometricObstacle,
        floor: Plane3D,
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
            label: Detection.obstacleLabel,
            confidence: 1,
            boundingBox: box,
            distance: Double(obstacle.nearestDistance),
            bearing: heading.bearing(to: obstacle.center),
            origin: .geometric,
            isHazard: true
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
