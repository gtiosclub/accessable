# AccessAble — Computer Vision

The codebase-aligned source of truth for the Computer Vision subteam: what the pipeline
does, how it is built, the data contracts it shares with the rest of the app, and the
status of every task. It describes the `cv-integration` branch as of October 2026 and
replaces the shared types and task specs in the original planning document wherever the
two disagree.

## What the pipeline does

The camera, LiDAR and device pose are turned into a short list of things that matter to
someone walking, and the ones in the way are announced through the app's announcement
engine:

> camera + LiDAR → perception → spatial reasoning → tracking → what is in the path →
> accessible speech and haptics

Everything on that path runs on the device. Nothing in it waits on the network, and the
future "Ask AI" feature (T19) stays outside it.

| Feature | What exists |
|---|---|
| F1 Obstacle & hazard detection | Geometric obstacles in the walking corridor (T11), kerbs, steps and drop-offs (T12), objects (T13) and people (T14), fused so a recognized obstacle is named once, tracked across frames (T15), announced on entry and threshold crossings (T16). |
| F2 LiDAR distance estimation | Filtered depth (T6), boxes mapped into the depth map (T5), robust per-object distance and bearing (T7), calibration and error metrics (T8). No relative-depth fallback on non-LiDAR devices; see limitations. |
| F3 Scene understanding | Instant offline "Describe my surroundings" (T18). On-device Ask AI on a still frame (T19). Maps location context and T21–T24 are not implemented. |
| F4 Text, signs & landmarks | OCR with confidence filtering and de-duplication (T17). Landmarks/POIs, OCR + GPS fusion and surface classification are not implemented. |
| F5 Camera / vision infrastructure | One shared ARKit session (T1), latest-frame-only processing (T3), orientation handling (T4), performance-mode throttling, on-device FPS/latency measurement and an evaluation toolkit (T20). Battery and thermal benchmarks and the recorded test set are still to do. |

## Architecture

```
ARSessionManager (T1, T2)           Services/Vision — the app's only ARSession
  world tracking, gravity-aligned; sceneDepth on LiDAR devices; T1 health checks
        │ every ARFrame, on the session's queue
        ▼
ARSceneAnalyzer                     Services/Vision — services.scene, services.sceneDescriber
  PerformanceMode frame stride → LatestOnlyProcessor (T3): newest frame only, own queue
        │
        ▼
ScenePerception.analyze             Services/Vision — one frame in, observation + events out
  ├─ Recognition: PeopleDetector (T14) + ObjectDetector (T13), upright boxes via T4
  ├─ Depth (LiDAR only): DepthMap (T6) built once per frame
  │    ├─ each recognized box → depth region (T5) → distance (T7) → world position,
  │    │  bearing, in-path test (T9)
  │    └─ point cloud → floor (T10) → geometric obstacles (T11) + ground profile → kerbs (T12)
  ├─ Fusion: obstacles overlapping a recognized box take its label
  ├─ ObjectTracker (T15): Detection.trackID
  ├─ ObstacleAnnouncer (T16): AnnouncementEvents for what is in the path
  ├─ TextReader (T17): OCR ≤ 1 Hz on its own queue; latest text attached
  └─ FrameTimer (T20): analysis FPS and latency
        │
        ├─► SceneObservation  → Broadcaster → UI (Camera guidance, Live detection)
        ├─► AnnouncementEvent → services.announcements (engine owned by Interaction, 3.3)
        └─► SceneDescriptionBuilder (T18) on request → "Describe my surroundings"
```

### Code layout

- `Models/Vision/` — the algorithms. No ARKit or UIKit, so the SwiftPM harness compiles and
  tests them on a Mac (`swift test`). Vision and Core ML are allowed; they run on macOS.
- `Models/Services/Vision/` — the runtime glue that needs ARKit or UIKit:
  `ARSessionManager`, `ARSceneAnalyzer`, `ScenePerception`, `TextReader`, and the
  interface-to-image orientation mapping. Verified by the iOS build and on device.
- `Models/Core/` — contracts shared with the other subteams (see below).

### Threading

- ARKit delivers frames on `ARSessionManager`'s serial queue. Handlers only hand the frame
  on; nothing heavy runs there.
- `LatestOnlyProcessor` keeps at most one frame pending. When analysis is slower than the
  camera, intermediate frames are dropped rather than queued, so the pipeline never works
  through a backlog and ARKit's frame-buffer pool never runs dry.
- `ScenePerception.analyze` runs on that processor's single queue. Its cross-frame state
  (tracker, announcer, timer, diagnostics) sits behind `Mutex`es.
- OCR runs on its own utility queue at most once a second.
- Announcements are yielded into an `AsyncStream` that one task drains into the sink, so
  they stay in order and the analysis queue never waits on the engine.
- Everything is Swift 6 strict concurrency. `@unchecked Sendable` appears only where Apple
  types are not `Sendable` (`ARFrame`, `CVPixelBuffer`, `VNCoreMLModel`), each with the
  invariant that makes it safe written next to it.

### Coordinate spaces

| Space | Used for | Notes |
|---|---|---|
| Upright normalized, top-left origin | Every `Detection.boundingBox` and `RecognizedText.boundingBox` | What Vision returns after the frame's orientation is applied (bottom-left origin, flipped once on conversion). |
| Sensor normalized, top-left origin | Reading the depth map | ARKit's captured image and depth map share the sensor's landscape orientation and field of view. `CGImagePropertyOrientation.sensorRect(fromUpright:)` converts; checked against Vision for all eight orientations. |
| World, metres, gravity-aligned | Point cloud, floor, corridor, obstacles | ARKit world space with +Y up. Bearings and the in-path test use the corridor flattened onto world up. |

Time inside the pipeline is `ARFrame.timestamp` (`TimeInterval`). `SceneObservation.timestamp`
and `AnnouncementEvent` dates stay wall-clock `Date`s for the UI and the engine.

## Shared data contracts

### Changed in `Models/Core` during integration

Both were approved by the tech lead and kept to the minimum. Nothing outside CV read the old
`trackID`.

| Contract | Change | Why |
|---|---|---|
| `Detection.trackID` | `Int?` → `UUID?` | Tracking (T15) and announcement state (T16) key objects by UUID; this is now how track identity reaches everyone. |
| `SceneObservation.elevationHazards` | New `[ElevationHazard]`, nearest first. `ElevationHazard` moved from `Models/Vision` to `Models/Core` with it. | The UI was reading hazards from the analyzer outside the contract. |

### Contracts CV produces and consumes

```swift
// Models/Core — shared with Maps and Interaction
struct Detection {               // one thing found in a frame
    let id: UUID                 // per frame
    var trackID: UUID?           // stable across frames (T15)
    var label: String            // "person", "chair", "obstacle" (geometry, unrecognized)…
    var confidence: Float
    var boundingBox: CGRect      // upright, normalized, top-left origin
    var distance: Double?        // metres from the camera, straight line; nil without LiDAR
    var bearing: RelativeBearing?// degrees from straight ahead, negative = left
    var origin: Origin           // .geometric, .model or .mesh (reserved)
    var isHazard: Bool           // something you could walk into or fall off
}

struct SceneObservation {        // one analyzed frame
    var timestamp: Date
    var detections: [Detection]
    var ground: GroundSurface
    var recognizedText: [RecognizedText]
    var elevationHazards: [ElevationHazard]
    var hasMetricDepth: Bool
}

struct ElevationHazard { let type: ElevationHazardType; let distance: Float; let heightChange: Float }
struct RecognizedText  { let id: UUID; var string: String; var confidence: Float; var boundingBox: CGRect }
struct AnnouncementEvent { category, priority, text, haptic, bearing, source, createdAt, expiresAt, dedupKey }

// Models/Services/ServiceProtocols.swift — what the rest of the app calls
protocol SceneObservationProviding { func observations() -> AsyncStream<SceneObservation>; func start() async throws; func stop() async }
protocol SceneDescribing { func describeCurrentScene() async -> String; func ask(_:locationContext:) async throws -> String }
protocol AnnouncementSink { func submit(_ event: AnnouncementEvent) async }
```

### CV-internal types (`Models/Vision`)

| Type | Purpose |
|---|---|
| `DepthMap` | One frame of LiDAR depth, copied out of ARKit once and filtered (range 0.2–6 m, confidence ≥ medium). Unreliable pixels are NaN. Replaces the planned `DepthFrame`. |
| `DepthFilter` | The range and confidence rules for `DepthMap`. |
| `DistanceEstimate` | `meters` (median), `validSampleCount`, `spread` (IQR). |
| `CameraIntrinsics` | Pinhole intrinsics, rescaled from the captured image to the depth map. |
| `Plane3D`, `FloorPlaneFit` | The fitted floor and how well it is supported. |
| `WalkingCorridor` | Origin, forward, right, width (0.9 m), max distance (4 m); `contains`, `distance(to:)`, `bearing(to:)`, `flattened(ontoFloorNormal:)`. |
| `GeometricObstacle` | Centre, nearest distance, width, height, whether it intersects the corridor. |
| `GroundSample` | One height reading of the surface ahead, input to T12. |
| `ObstacleAlertInput` | A tracked `Detection` plus whether it is in the path this frame; the announcer's input. |
| Evaluation | `GroundTruthDetection`, `DetectionTestCase`, `DetectionMetrics`, `DistanceTestCase`, `DistanceMetrics` (MAE, RMSE, max, bias, count), `DistanceCalibration`, `FrameTiming`, `PerformanceMetrics`, `FrameTimer`, `TestSetManifest`. |

### Planned types that were not kept

| Planned | Now |
|---|---|
| The four-field `Detection` (id, label, confidence, box) | The existing, richer core `Detection` above. One type flows end to end. |
| `DepthFrame` (raw buffers + timestamp) | `DepthMap` (filtered, plain values) plus `ARFrame.timestamp`. |
| `TrackedObject` | Tracking writes `Detection.trackID`; track state is private to `ObjectTracker`. |
| `ObstacleAlert`, `ObstacleAlertType` | `AnnouncementEvent`, the contract the announcement engine already consumes. |
| `AlertState` | Private to `ObstacleAnnouncer`. |
| `SceneEntity` (T18 input) | `SceneObservation`. |
| `CalibrationSample`, `CalibrationReport` (T8) | `DistanceTestCase`, `DistanceMetrics`, shared with T20. |
| `AIQuery`, `AIResponse` (T19) | `SceneDescribing.ask(_:locationContext:)`, already the app's contract. Internally `AskAI.answer(_:imageData:)` returns `AskAIResponse` (answer, latency in ms). |

## Architectural decisions

1. **One session owner.** `ARSessionManager` is the only `ARSession` in the app; the analyzer
   subscribes to it and the Live screen previews it. Two sessions would fight over the camera.
2. **Latest frame only.** Stale frames are dropped, never queued. `PerformanceMode` thins the
   input further (every 2nd ARKit frame normally, every 3rd in battery mode).
3. **`sceneDepth`, not `smoothedSceneDepth`.** Smoothed depth averages several frames and lags
   behind anything moving toward the user. Nothing needs it today.
4. **Filter depth once.** `DepthMap` applies range and confidence rules once per frame; the
   point cloud and object distances read the same filtered values.
5. **Rotate, don't rescale, into the depth map.** Detection boxes are upright; the depth map is
   in sensor orientation. T5 undoes the rotation, verified against Vision itself.
6. **Geometry decides "in the way"; models name things.** A geometric obstacle needs no label to
   be announced. When a recognized box overlaps it, it takes the label. Recognized objects
   count as in the path only if they are hazard classes or people and their 3D position is in
   the corridor.
7. **Identity before announcing.** Announcements key on track IDs, so each object is announced
   once per distance band, not once per frame.
8. **CV never speaks.** Announcements are `AnnouncementEvent`s with priority, haptic, bearing,
   dedup key and a 1.5 s expiry; the engine (3.3) applies the user's profile and decides.
9. **OCR is off the safety path.** It runs beside the pipeline at most once a second.
10. **Swappable object model.** `ObjectDetector` takes the model name; any Core ML detector
    exported with built-in NMS drops in. `hazardLabels` is the only COCO-specific part.

## Task status (T1–T20)

"Integrated" means the code runs in the live pipeline. Nothing below has been checked on
a physical device by the integrator; see **Device validation**.

| Task | Owner | PR | Status | Where | What changed in integration |
|---|---|---|---|---|---|
| T1 Shared ARKit session | Deshna | #106 | Integrated | `ARSessionManager`, `FrameHealthCheck` | Became the only session; analyzer moved onto it. Health checks shown on Live detection. |
| T2 LiDAR depth | Smitha | #104 | Integrated | `ARSessionManager`, `DepthMap` | Config lives in the session manager. `sceneDepth` only. `DepthMap` instead of `DepthFrame`. |
| T3 Latest-frame-only queue | Sahiti | #101 | Rewritten, integrated | `LatestOnlyProcessor` | Generic, ARKit-free, `Mutex`-based, own queue, `cancelPending()`; tested. |
| T4 Camera orientation | Sahiti | #101 | Rewritten, integrated | `CameraImageOrientation.swift` | One mapping, replacing a duplicate; lives in Services (UIKit). |
| T5 RGB-to-depth mapping | Sahiti | #101 | Rewritten, integrated | `DepthCoordinateMapping.swift` | Now undoes the image rotation (the original only rescaled). Returns normalized depth-map coordinates. |
| T6 Depth filtering | Sahiti | #101 | Rewritten, integrated | `DepthMap.swift` | Copies and filters once per frame instead of locking per pixel (~11 ms/frame before). |
| T7 Object distance | Petr | #99 | Integrated | `DetectionDistanceEstimator.swift`, `ObjectLocation.swift` | Reads `DepthMap`; samples the box centre first. Also yields bearing and in-path. |
| T8 Distance calibration | Petr | #100 | Merged with T20 | `Evaluation/DistanceEvaluation.swift` | One metrics type with T20; affine fit kept. Needs real measurements. |
| T9 Walking corridor | Petr | #102 | Integrated | `WalkingCorridor.swift` | `contains` is a method; fixed the flattened lateral axis pointing left. |
| T10 Floor plane | Rison | direct commit | Integrated | `FloorPlaneDetector.swift` | Unchanged. |
| T11 Geometric obstacles | Rison | direct commit | Integrated | `GeometricObstacleDetector.swift` | Uses `WalkingCorridor.contains`. |
| T12 Curbs, drop-offs | Rison | direct commit | Integrated | `GroundProfiler.swift`, `ElevationHazardDetector.swift` | Hazards now in `SceneObservation` and announced. |
| T13 YOLO / Core ML | Deshna | #107 | Integrated | `ObjectDetector.swift`, `DetectionFusion.swift` | Lazy model load, 0.5 threshold, people left to T14, fusion with geometry added. |
| T14 People detection | Rison | direct commit | Integrated | `PeopleDetector.swift` | Unchanged; people now get distances. |
| T15 Object tracking | Petr | #103 | Integrated | `ObjectTracker.swift` | ARKit time, age-based expiry, generic "obstacle" label compatible, writes `trackID`. Image velocity dropped (unused). |
| T16 Alert thresholds | Smitha | #105 | Rewritten, integrated | `ObstacleAnnouncer.swift` | Emits `AnnouncementEvent`s; exit grace period, state pruning, elevation hazards, priority and haptic mapping. |
| T17 OCR | Smitha | #114 | Integrated | `TextDetector.swift`, `RecognizedTextMemory.swift`, `TextReader.swift` | Off the safety path at ≤1 Hz; confidence filter and de-duplication. |
| T18 Instant descriptions | Smitha | #112 | Integrated | `SceneDescriptionBuilder.swift` | Hazards first, capped at four items, speakable empty scene; serves `describeCurrentScene()`. |
| T19 Ask AI | Deshna, Nish | #144 | Integrated, not on device yet | `AskAI.swift`, `ImageFacts.swift`, `ARSceneAnalyzer.ask` | On-device only. Facts: the latest `SceneObservation` (objects, people, kerbs with distance and direction, as in T18) plus text (T17's `TextDetector`), scene labels and each object's main colour read from one still frame. Foundation Models answers from those facts, a template where Apple Intelligence is unavailable; iOS 26's model is text-only, so it never sees the image. Outside the obstacle pipeline. Camera guidance screen has an Ask AI section; Home has none yet. If the model fails (guardrail, context window), the template answers instead. The answer is spoken only through VoiceOver until the announcement engine (3.3) lands. |
| T20 Test set & metrics | Deshna | #122 | Metrics integrated; data missing | `Evaluation/`, `TestSet/` | Live FPS/latency on the Live screen. `TestSet/annotations.json` has no frames yet. |

### Task descriptions that changed

- **T2** — "Expose scene depth and smoothed depth" → expose `sceneDepth` only, as a filtered `DepthMap`.
- **T5** — "Scale an RGB box into the depth map" → convert an upright box into sensor-orientation coordinates for the current interface orientation; the result is normalized depth-map coordinates.
- **T6** — "Per-pixel reliable-depth lookup" → build one filtered `DepthMap` per frame that every consumer reads.
- **T7** — Input is a normalized depth-map region and a `DepthMap`; output also feeds world position, bearing and the in-path test.
- **T8** — Folded into T20's distance evaluation; the affine calibration fit remains T8's contribution.
- **T15** — Output is `Detection.trackID`, not a `TrackedObject` list; image velocity deferred.
- **T16** — "Obstacle alert state machine" → "obstacle announcement policy" producing `AnnouncementEvent`s, covering elevation hazards too.
- **T17** — Adds cadence limiting and de-duplication; runs outside the per-frame pipeline.
- **T18** — Input is `SceneObservation`; output capped to the most important items.
- **New: semantic–geometric fusion** — labelling geometric obstacles with recognized objects (`DetectionFusion.swift`). Done.
- **New: pipeline wiring (1.4)** — `AppServices.live` runs the analyzer on ARKit devices. Done.

## Known limitations

- **No device validation yet.** Everything below "Device validation" is unverified on hardware.
- **Non-LiDAR devices** get recognized objects and people without distances. Nothing
  distance-based is announced, and there is no relative-depth fallback.
- **YOLO11 is AGPL-3.0** (Ultralytics). Fine for the club build; it must be replaced with a
  permissively licensed model, or licensed commercially, before any App Store or other public
  distribution.
- **Model false positives.** On abstract wallpapers the model reported "spoon" (0.51) and
  "vase" (0.59) even at the 0.5 threshold. They are non-hazard classes, so they reach scene
  descriptions but not warnings. Tune the threshold, and possibly per class, with real data.
- **Portrait only in practice.** The Live and guidance screens set portrait orientation;
  other orientations are mapped correctly but not exercised.
- **Announcements are untested end to end with real speech**: the announcement engine is still
  the placeholder until Interaction's engine (3.3) lands.
- **Tracking is box-overlap only.** Fast lateral motion at a low analysis rate can split a
  track and repeat an announcement.
- **Thresholds are fixed** (3/2/1 m bands, 0.9 m corridor); `GuidanceProfile` cannot adjust them yet.
- **Detection boxes for geometric obstacles** assume a square footprint (depth is not measured).

## Device validation checklist

Run on a LiDAR iPhone (12 Pro or newer), using Home → Live detection for readouts and
Camera guidance for announcements:

1. T1: tracking reads "normal", camera ~60 fps, and the "move the phone" hint clears.
2. Analysis rate and latency (T20 line): target ≥ 10 fps and p95 under 100 ms in normal mode;
   check battery mode and after 10 minutes for thermal throttling.
3. Floor: camera height reads 1.1–1.5 m held at chest height (T10).
4. Distances: tape-measure a chair at 1, 2 and 3 m; record `DistanceTestCase`s and run
   `evaluateDistances` / `fitDistanceCalibration` (T7, T8).
5. Left/right: an object to the right is announced "on your right" (T9 handedness fix).
6. Fusion: a chair in the path is announced once as "Chair", not as "obstacle" plus "chair".
7. Announcements: walking toward a chair produces one announcement per band (3, 2, 1 m) and
   no repeats while standing still or when it flickers at the corridor edge (T15, T16).
8. Kerb and step down outdoors are announced; a drop-off is at least high priority (T12, T16).
9. OCR: a room sign shows up in "Describe my surroundings" once, and disappears a few seconds
   after looking away (T17, T18).
10. No "delegate is retaining N ARFrames" warnings in the console (T3).

## Next phase

- **Phone pose check** — use the camera pitch from the pose to tell the user when the camera
  points at the floor or sky. The handoff document calls for it; no task covers it.
- **Local safe-path guidance** — find open space beside an obstacle in the corridor and turn it
  into "move slightly right", the core product goal beyond warnings.
- **T19 Ask AI on device** — check answers and latency on a real iPhone, with and without
  Apple Intelligence; add an Ask AI entry point to Home. Then **T21–T24** (AI modes,
  personalization, safety rules), outside the obstacle pipeline.
- **Motion** — track velocity and approach rate for people and moving objects (deferred from T15).
- **Recorded test set** — capture and annotate the eleven T20 scenarios; run detection and
  distance evaluation on every model or threshold change.
- **Model licence** — choose and integrate a permissively licensed detector.
- **Profile-driven thresholds** — let `GuidanceProfile` set announcement bands and verbosity.
- **ARKit mesh classification** (`Detection.Origin.mesh`, `PerformanceMode.meshReconstructionEnabled`)
  is reserved in the contracts but unused.

## Testing

```bash
swift test --scratch-path /tmp/accessable-build
```

159 tests in 29 suites cover everything in `Models/Vision` and the shared phrasing, including
the T5 orientation mapping against Vision for all eight orientations, T6 filtering on real
pixel buffers, T13 and T17 against the bundled test image, and the T16 announcement rules.
`Models/Services/Vision` is covered by the iOS build and the device checklist above.
