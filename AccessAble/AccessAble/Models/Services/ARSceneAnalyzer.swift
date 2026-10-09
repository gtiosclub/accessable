import ARKit
import CoreVideo
import Foundation
import Synchronization
import UIKit
import os
import simd

/// Owner: Computer Vision (1.4). Drives the 1.1 detectors off a live ARKit session.
///
/// One ARKit session feeds everything: `capturedImage` goes to Vision for people (T14),
/// and `sceneDepth` is unprojected into a point cloud for the floor fit (T10), geometric
/// obstacles (T11) and the ground profile behind kerb detection (T12).
///
/// `@unchecked Sendable` because `ARSession` and `ARFrame` are not `Sendable`. The
/// invariants that make it safe: every mutable field lives behind `state`, the session is
/// only configured from the main actor, and all frame analysis happens on `analysisQueue`,
/// which is also the session's delegate queue — so frames are handled one at a time and
/// never escape it.
final class ARSceneAnalyzer: NSObject, SceneObservationProviding, @unchecked Sendable {
    /// Exposed so a preview view can render this exact session. Touch it only from the
    /// main actor.
    let session = ARSession()

    private let peopleDetector: PeopleDetector
    private let corridorWidth: Float
    private let corridorDistance: Float
    private let performance: any PerformanceModeProviding

    private let broadcaster = Broadcaster<SceneObservation>(replaysLatest: true)
    private let analysisQueue = DispatchQueue(label: "AccessAble.ARSceneAnalyzer.analysis")
    private let log = Logger(subsystem: "AccessAble", category: "ARSceneAnalyzer")

    private struct State {
        var frameCounter = 0
        var frameStride = PerformanceMode.normal.detectionFrameStride
        /// How `capturedImage` is rotated relative to upright. ARKit delivers it
        /// landscape-right, so a portrait UI needs `.right`.
        var imageOrientation: CGImagePropertyOrientation = .right
        var interfaceOrientation: UIInterfaceOrientation = .portrait
        var floor: Plane3D?
        /// Signed height of the camera above the fitted floor, in metres. A good live
        /// sanity check on T10: held normally it should read roughly 1.1 to 1.5 m.
        var cameraHeight: Float?
        var hazards: [ElevationHazard] = []
        /// width / height of the frame once rotated upright. Overlays need it to map a
        /// normalized box onto an aspect-filled preview.
        var uprightAspectRatio: Float = 3.0 / 4.0
        var hasDepth = false
    }

    private let state = Mutex(State())
    private let modeTask = Mutex<Task<Void, Never>?>(nil)

    init(
        peopleDetector: PeopleDetector = PeopleDetector(),
        performance: any PerformanceModeProviding,
        corridorWidth: Float = WalkingCorridor.default.width,
        corridorDistance: Float = WalkingCorridor.default.maxDistance
    ) {
        self.peopleDetector = peopleDetector
        self.performance = performance
        self.corridorWidth = corridorWidth
        self.corridorDistance = corridorDistance
        super.init()
    }

    // MARK: - SceneObservationProviding

    func observations() -> AsyncStream<SceneObservation> {
        broadcaster.stream()
    }

    func start() async throws {
        guard ARWorldTrackingConfiguration.isSupported else {
            throw ARSceneAnalyzerError.worldTrackingUnsupported
        }

        let configuration = ARWorldTrackingConfiguration()
        // Gravity alignment puts world +Y along "up", which is exactly the assumption
        // `FloorDetectionTuning.upHint` makes. Without it the floor fit has no idea which
        // way is down.
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []

        let depthSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        if depthSupported {
            configuration.frameSemantics.insert(.sceneDepth)
        } else {
            // Not fatal. People detection still works; the geometry tasks go quiet and
            // `hasMetricDepth` stays false, which is the fallback the shared contract
            // already documents for non-LiDAR devices.
            log.notice("sceneDepth unsupported — running without geometry")
        }
        state.withLock { $0.hasDepth = depthSupported }

        await MainActor.run {
            session.delegate = self
            session.delegateQueue = analysisQueue
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        }

        // Adapt the frame stride to the global performance mode (owned by 3.3).
        let task = Task { [weak self] in
            guard let self else { return }
            for await mode in performance.modes() {
                state.withLock { $0.frameStride = max(1, mode.detectionFrameStride) }
            }
        }
        modeTask.withLock { $0?.cancel(); $0 = task }
    }

    func stop() async {
        modeTask.withLock { $0?.cancel(); $0 = nil }
        await MainActor.run { session.pause() }
    }

    // MARK: - Demo/overlay accessors

    /// Latest elevation hazards. Not part of `SceneObservation`, which only carries a
    /// coarse `GroundSurface`, so a UI that wants the measured heights reads them here.
    var latestHazards: [ElevationHazard] { state.withLock { $0.hazards } }
    var latestFloor: Plane3D? { state.withLock { $0.floor } }
    var cameraHeightAboveFloor: Float? { state.withLock { $0.cameraHeight } }
    var uprightAspectRatio: Float { state.withLock { $0.uprightAspectRatio } }
    var isDepthAvailable: Bool { state.withLock { $0.hasDepth } }

    /// Tell the analyzer how the device is held, so Vision gets the right orientation and
    /// projected boxes land in the right place.
    func setInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        state.withLock {
            $0.interfaceOrientation = orientation
            $0.imageOrientation = switch orientation {
            case .portrait: .right
            case .portraitUpsideDown: .left
            case .landscapeLeft: .down
            case .landscapeRight: .up
            default: .right
            }
        }
    }
}

// MARK: - ARSessionDelegate

extension ARSceneAnalyzer: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let shouldAnalyze = state.withLock { state -> Bool in
            state.frameCounter += 1
            return state.frameCounter % state.frameStride == 0
        }
        guard shouldAnalyze else { return }
        broadcaster.send(analyze(frame))
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        log.error("ARKit session failed: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - Per-frame analysis

private extension ARSceneAnalyzer {
    func analyze(_ frame: ARFrame) -> SceneObservation {
        let snapshot = state.withLock { ($0.imageOrientation, $0.interfaceOrientation) }
        let imageResolution = frame.camera.imageResolution
        let upright = uprightSize(for: imageResolution, orientation: snapshot.1)
        state.withLock { $0.uprightAspectRatio = Float(upright.width / upright.height) }

        var detections: [Detection] = []

        // T14 — people, with real bounding boxes.
        do {
            detections += try peopleDetector.detect(
                pixelBuffer: frame.capturedImage,
                orientation: snapshot.0
            )
        } catch {
            log.error("people detection failed: \(error.localizedDescription, privacy: .public)")
        }

        var ground = GroundSurface.unknown
        var hasMetricDepth = false
        var hazards: [ElevationHazard] = []

        if let depth = frame.sceneDepth {
            hasMetricDepth = true
            let cloud = pointCloud(from: depth, camera: frame.camera)
            let corridor = corridor(for: frame.camera)

            // T10 — the floor everything else is measured against.
            if let fit = detectFloorPlane(points: cloud) {
                let height = distanceFromPlane(point: corridor.origin, plane: fit.plane)
                state.withLock {
                    $0.floor = fit.plane
                    $0.cameraHeight = height
                }

                // T11 — obstacles by geometry, no labels needed.
                let obstacles = detectObstacles(points: cloud, floor: fit.plane, corridor: corridor)
                detections += obstacles
                    .filter(\.intersectsWalkingCorridor)
                    .compactMap {
                        detection(
                            for: $0, floor: fit.plane, corridor: corridor,
                            camera: frame.camera, orientation: snapshot.1, viewportSize: upright
                        )
                    }

                // T12 — kerbs and drop-offs in the surface itself.
                let profile = groundProfile(points: cloud, floor: fit.plane, corridor: corridor)
                hazards = detectElevationHazards(samples: profile)
                ground = groundSurface(for: hazards)
            }
        }

        state.withLock { $0.hazards = hazards }

        return SceneObservation(
            timestamp: .now,
            detections: detections,
            ground: ground,
            recognizedText: [],
            hasMetricDepth: hasMetricDepth
        )
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

    func pointCloud(from depth: ARDepthData, camera: ARCamera) -> [SIMD3<Float>] {
        let depthMap = depth.depthMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        guard CVPixelBufferLockBaseAddress(depthMap, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return [] }
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)

        // ARKit's intrinsics describe the captured image, which is far larger than the
        // depth map — rescale or the cloud comes out subtly wrong.
        let intrinsics = CameraIntrinsics(
            focalX: camera.intrinsics[0][0],
            focalY: camera.intrinsics[1][1],
            principalX: camera.intrinsics[2][0],
            principalY: camera.intrinsics[2][1],
            imageWidth: Int(camera.imageResolution.width),
            imageHeight: Int(camera.imageResolution.height)
        ).scaled(toWidth: width, height: height)

        let readDepth: (Int, Int) -> Float = { column, row in
            depthBase
                .advanced(by: row * depthRowBytes + column * 4)
                .assumingMemoryBound(to: Float32.self)
                .pointee
        }

        guard let confidenceMap = depth.confidenceMap,
              CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) == kCVReturnSuccess
        else {
            return unprojectDepthMap(
                width: width, height: height, intrinsics: intrinsics,
                cameraTransform: camera.transform, depthAt: readDepth
            )
        }
        defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }

        guard let confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap) else {
            return unprojectDepthMap(
                width: width, height: height, intrinsics: intrinsics,
                cameraTransform: camera.transform, depthAt: readDepth
            )
        }
        let confidenceRowBytes = CVPixelBufferGetBytesPerRow(confidenceMap)

        return unprojectDepthMap(
            width: width, height: height,
            intrinsics: intrinsics,
            cameraTransform: camera.transform,
            depthAt: readDepth,
            isConfident: { column, row in
                // Low-confidence LiDAR returns are the main source of phantom obstacles.
                let raw = confidenceBase
                    .advanced(by: row * confidenceRowBytes + column)
                    .assumingMemoryBound(to: UInt8.self)
                    .pointee
                return raw >= ARConfidenceLevel.medium.rawValue
            }
        )
    }

    /// Wraps a geometric obstacle as a `Detection`, projecting its 3D extent back into
    /// normalized image space so the UI can draw a box around it.
    func detection(
        for obstacle: GeometricObstacle,
        floor: Plane3D,
        corridor: WalkingCorridor,
        camera: ARCamera,
        orientation: UIInterfaceOrientation,
        viewportSize: CGSize
    ) -> Detection? {
        guard let box = projectedBoundingBox(
            obstacle: obstacle, floor: floor, corridor: corridor,
            camera: camera, orientation: orientation, viewportSize: viewportSize
        ) else { return nil }

        let offset = obstacle.center - corridor.origin
        let along = simd_dot(offset, corridor.forward)
        let lateral = simd_dot(offset, corridor.right)

        return Detection(
            label: "obstacle",
            confidence: 1,
            boundingBox: box,
            distance: Double(obstacle.nearestDistance),
            bearing: RelativeBearing(degrees: Double(atan2(lateral, max(along, 0.01)) * 180 / .pi)),
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

enum ARSceneAnalyzerError: LocalizedError {
    case worldTrackingUnsupported

    var errorDescription: String? {
        switch self {
        case .worldTrackingUnsupported:
            "This device does not support ARKit world tracking, so camera guidance is unavailable."
        }
    }
}
