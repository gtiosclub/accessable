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

The pipeline runs while the camera screen (Camera guidance) is open, and for the whole of an
active trip (`TripCameraCoordinator`). "Describe my surroundings" wakes it for one frame when
it is off. All of them share one camera: `ARSceneAnalyzer.start()` and `stop()` nest.

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
  │    └─ point cloud → floor (T10, remembered by FloorMemory when out of view)
  │         → geometric obstacles (T11), named by shape (wall, pole, low obstacle)
  │         → LocalOccupancyMap: every point folded into a floor grid kept across frames
  │              → planPath: carry on / step aside / turn, read from the map, not the frame
  │         → ground profile → kerbs (T12), on a measured floor only
  ├─ Fusion: obstacles overlapping a recognized box take its label
  ├─ ObjectTracker (T15): Detection.trackID
  ├─ ObstacleAnnouncer (T16): AnnouncementEvents about the path — blocked at 3/2/1 m with
  │    the way round, "Path clear" — confirmed over frames, with hysteresis and cooldowns
  ├─ NavigationGuide ("Take me to…"): matches detections and signs to the request, keeps
  │    the target's world position, steers by camera pose; one instruction every few seconds
  ├─ TextReader (T17): OCR ≤ 1 Hz on its own queue; latest text attached
  └─ FrameTimer (T20): analysis FPS and latency
        │
        ├─► SceneObservation  → Broadcaster → UI (the camera screen, LiveSceneView)
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
| `AnnouncementEvent.hapticOnly` | New `Bool`, default `false`. The engine plays the haptic and skips speech, unless the user has haptics off or the event has no haptic. | A second warning about the same kind of thing within 20 s is a buzz, not another sentence. |
| `GuidanceProfile.alertFilter` | New `AlertFilter` (danger bar and warning distance), default medium-and-above within 2.5 m. Older saved profiles load with the default. | The user's alert settings from the Live screen apply on trips too. |

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
11. **One limit on how much the camera says.** Each announcer keeps itself quiet, but none
    knows what the others said. `SpeechBudget` runs after all of them: at most one event per
    frame (the most urgent), and nothing spoken within 3 s of the last unless it is more
    urgent. "Stop" always gets through; haptic-only events don't use up the gap.
12. **The user chooses what is worth hearing.** `DangerLevel` rates every label (vehicles and
    drop-offs critical; poles, kerbs and anything unnamed high; furniture and people medium;
    things on a table low). `AlertFilter` drops what is below the user's bar and moves the
    first warning to their distance. Two things are never filtered: anything in the path
    inside the 1.2 m "Stop" band, and drop-offs, which also keep at least 2.5 m.
13. **Quiet by default.** The 2.5 m warning goes haptic-only for a repeat of the same kind of
    thing within 20 s; "Stop" is not repeated to someone standing still; advice changes are
    spoken at most every 8 s; approaching people are announced only when urgent (< 1.5 s).
14. **The Live screen shows what the voice says.** The status strip and the one outline come
    from the announcer's own confirmed warning (`ObstacleAnnouncer.currentWarning`), not a
    separate per-frame guess, so the screen can't say "Path clear" while the voice says "Stop",
    and it inherits the announcer's confirmation and hysteresis instead of flickering. Every detection box, the readout and the
    field-test recorder are developer tools, compiled into debug builds only and switched on
    with the wrench in the toolbar.

15. **A fall across a depth hole is believed only up close.** Lower ground past a hole is how a
    real edge looks (the edge hides the ground just beyond it), but indoors a hole is usually
    a dark rug, a chair base or someone's feet. The fall is reported as a step down or
    drop-off only within 3 m and with at least three bins of ground on each side; otherwise
    it stays `.unknown`, which is never spoken.

16. **Say how far, then say when.** A sidestep is spoken in steps of half a metre ("Two steps
    right"), up to three; farther than that it is a clock direction ("Bear right, 2 o'clock").
    Once the user has followed it and the corridor ahead is empty, they hear "Straight ahead
    now" after 0.4 s instead of the usual 1 s, and the speech limits don't hold it back. "Stop"
    gives the instruction rather than the name ("Stop. One step right."); the screen names it.
17. **"Stop" doesn't wait when it is an escalation.** Something already confirmed at warning
    distance that comes inside 1.2 m is "Stop" on that frame. A first sighting that close still
    needs two frames, so one frame of depth speckle never says "Stop".
18. **The mesh runs only for "take me to…".** Building the classified mesh (T36) pulled the
    camera from 60 to about 34 fps on device and slowed every frame. It is now switched on
    when a request starts and off when it ends, without restarting tracking. Outside a
    request, doors from the mesh are not available (Describe still has the camera's view).
    The developer readout shows each stage's time (Objects, Crosswalk, Mesh, Depth, Warnings).

19. **Modes, after Apple Magnifier.** Walk / Find / Read / Describe (`LiveMode`). Each runs only
    what it needs: OCR in Find and Read, the mesh in Find, crosswalks, street signs, approaches,
    crowds and ground segmentation in Walk. Outside Walk, obstacle announcers are heard only at
    "Stop". Trips run in Walk.
20. **Signs, after InView.** `SignInterpreter` (adapted from InView's AccessCore) normalizes plates
    ("RM. 204A / CHEMISTRY LAB" → "Room 204A, Chemistry Lab"), repairs OCR's O-for-0 in numbers,
    and rejects posters and prices. `SignAnnouncer` groups lines into plates and speaks a sign
    once two reads agree, with a clock direction and distance from depth. "Take me to Room 0266"
    matches room numbers, not the word "room".
21. **Direction you can hear and feel, after Project Guideline.** Short of "Stop", a warning with a
    way round buzzes the turnLeft / turnRight pattern. With Sound cues on (the profile's spatial
    audio channel), a beep placed in 3D on the side to move towards repeats faster for a bigger
    sidestep and rises in pitch as the obstacle nears (`SteeringCue`, `SteeringTones`).
22. **Ground segmentation checks drop-offs.** Apple's Core ML DETR (COCO-panoptic, about 18 ms on the
    Neural Engine) runs beside the pipeline in Walk, every 0.4 s (`SurfaceReader`). A step down or
    drop-off with the same level ground just before and after it, and no stairs, is dismissed.
    "Stairs ahead" is spoken from segmentation; "Road / water / railway ahead" only with outdoor
    evidence (sky, trees, buildings, no ceiling), because on field recordings the model called
    grey carpet "road" while the outdoor share was 0% in every indoor frame. The 86 MB model is
    not in git: `sh Scripts/download-models.sh`. Without it the app runs as before.

23. **One camera screen.** T29's "Read signs & text" screen and T30's Camera guidance preview
    became modes of `LiveSceneView` rather than separate screens: the Home buttons and the Siri
    shortcut open it in Walk or Read. T29's per-session dedup gave way to `SignAnnouncer` (two
    agreeing reads, a 30 s repeat, clock and distance); T30's Ask AI moved into Describe mode,
    where the answer is now also spoken; its all-boxes overlay, coloured by raw distance, gave
    way to the one outline that follows the spoken warning and the user's alert distance.

## Task status (T1–T20, T31)

"Integrated" means the code runs in the live pipeline. Nothing below has been checked on
a physical device by the integrator; see **Device validation**.

| Task | Owner | PR | Status | Where | What changed in integration |
|---|---|---|---|---|---|
| T1 Shared ARKit session | Deshna | #106 | Integrated | `ARSessionManager`, `FrameHealthCheck` | Became the only session; analyzer moved onto it. Health checks shown in the camera screen's developer readout. |
| T2 LiDAR depth | Smitha | #104 | Integrated | `ARSessionManager`, `DepthMap` | Config lives in the session manager. `sceneDepth` only. `DepthMap` instead of `DepthFrame`. |
| T3 Latest-frame-only queue | Sahiti | #101 | Rewritten, integrated | `LatestOnlyProcessor` | Generic, ARKit-free, `Mutex`-based, own queue, `cancelPending()`; tested. |
| T4 Camera orientation | Sahiti | #101 | Rewritten, integrated | `CameraImageOrientation.swift` | One mapping, replacing a duplicate; lives in Services (UIKit). |
| T5 RGB-to-depth mapping | Sahiti | #101 | Rewritten, integrated | `DepthCoordinateMapping.swift` | Now undoes the image rotation (the original only rescaled). Returns normalized depth-map coordinates. |
| T6 Depth filtering | Sahiti | #101 | Rewritten, integrated | `DepthMap.swift` | Copies and filters once per frame instead of locking per pixel (~11 ms/frame before). |
| T7 Object distance | Petr | #99 | Integrated | `DetectionDistanceEstimator.swift`, `ObjectLocation.swift` | Reads `DepthMap`; samples the box centre first. Also yields bearing and in-path. |
| T8 Distance calibration | Petr | #100 | Merged with T20 | `Evaluation/DistanceEvaluation.swift` | One metrics type with T20; affine fit kept. Needs real measurements. |
| T9 Walking corridor | Petr | #102 | Integrated | `WalkingCorridor.swift` | `contains` is a method; fixed the flattened lateral axis pointing left. |
| T10 Floor plane | Rison | direct commit | Integrated | `FloorPlaneDetector.swift`, `FloorMemory.swift` | Support ratio lowered to 8% so a strip of floor at the bottom of the frame still fits; refinement re-checked for tilt (it could rotate a candidate into a wall). `FloorMemory` carries the floor across frames: the last fit for 1.5 s, then a level plane at the remembered camera height, so obstacles are still measured with no floor in view. Fits putting the camera outside 0.4–2.5 m, jumping more than 0.35 m, or tilted past 30° are rejected. |
| T11 Geometric obstacles | Rison | direct commit | Integrated | `GeometricObstacleDetector.swift`, `LocalOccupancyMap.swift`, `PathClearance.swift` | Uses `WalkingCorridor.contains`. Obstacles carry corridor-relative extents and a shape `Kind` (wall, pole, low obstacle, obstacle); `coverageProfile` tells a wall from a narrow view of one. Guidance no longer comes from the frame: `LocalOccupancyMap` is a 16 m, 0.1 m grid in ARKit's world that every depth point updates — the cell it lands in is hit, the cells its ray crossed are seen through — one update per cell per frame as log-odds. `planPath` reads it: how far a corridor-wide lane stays free straight ahead, at each sidestep, and at each turn. Sidesteps are offered only into lanes the scan has seen free (≥40% known-free cells); turns may point at the unknown. The map remembers the wall after the user turns, which is what stops the advice flipping. |
| T12 Curbs, drop-offs | Rison | direct commit | Integrated | `GroundProfiler.swift`, `ElevationHazardDetector.swift` | Hazards now in `SceneObservation` and announced. The profile starts 0.5 m out, takes nothing above 0.3 m, and cuts out T11's obstacle footprints — a chair leg standing in a bin otherwise outnumbers the floor and reads as "step up, then drop-off" (seen in the 17 Oct demo). A rise that falls back within 0.6 m is an object, not terrain, and is dropped. Hazards need 3 frames to confirm. |
| T13 YOLO / Core ML | Deshna | #107 | Integrated | `ObjectDetector.swift`, `DetectionFusion.swift` | Lazy model load, 0.5 threshold, people left to T14, fusion with geometry added. Fusion is strict: only `fusableLabels` (collidable things and people) transfer, the boxes must overlap mutually (≥50% of the smaller, ≥20% of the larger) and their depths must agree within 0.5 m or 25%. Before that a seated person behind a chair renamed the chair "person", and a phone on a desk renamed the desk. The bundled model itself (originally YOLO11n) was replaced by T31 — see that row below and "Known limitations". |
| T14 People detection | Rison | direct commit | Integrated | `PeopleDetector.swift` | Unchanged; people now get distances. |
| T15 Object tracking | Petr | #103 | Integrated | `ObjectTracker.swift` | ARKit time, age-based expiry, generic "obstacle" label compatible, writes `trackID`. Image velocity dropped (unused). |
| T16 Alert thresholds | Smitha | #105 | Rewritten twice, integrated | `ObstacleAnnouncer.swift` | Emits `AnnouncementEvent`s about the *path*, not per object. The occupancy map's blocked distance sets the band (`BlockedAhead`); detections only name what blocks ("chair", "wall", else "obstacle"). Two bands by default: a warning with the way round at 2.5 m, "Stop" at 1.2 m. Spoken when first confirmed (2 frames, 0.35 m hysteresis), on escalation, when the advice changes — and a new direction must hold 1 s to count, then wait 4 s since the last word — and as a reminder every 8 s at the stop band. "Path clear" only after a stop. At most one announcement per 2.5 s unless more urgent; navigation cues wait 2.5 s after a path warning. Phrasing is short: "Chair ahead. Go left." / "Stop. Wall ahead. Turn right." / "Stop. Wall ahead. No clear path. Turn around slowly." Kerbs and steps: same rules per type, 3 frames to confirm, 8 s repeat hold; `.unknown` not spoken. |
| T17 OCR | Smitha | #114 | Integrated | `TextDetector.swift`, `RecognizedTextMemory.swift`, `TextReader.swift` | Off the safety path at ≤1 Hz; confidence filter and de-duplication. |
| T18 Instant descriptions | Smitha | #112 | Integrated | `SceneDescriptionBuilder.swift` | Hazards first, capped at four items, speakable empty scene; serves `describeCurrentScene()`. |
| T19 Ask AI | Deshna, Nish | #144 | Integrated, not on device yet | `AskAI.swift`, `ImageFacts.swift`, `ARSceneAnalyzer.ask` | On-device only. Facts: the latest `SceneObservation` (objects, people, kerbs with distance and direction, as in T18) plus text (T17's `TextDetector`), scene labels and each object's main colour read from one still frame. Foundation Models answers from those facts, a template where Apple Intelligence is unavailable; iOS 26's model is text-only, so it never sees the image. Outside the obstacle pipeline. Camera guidance screen has an Ask AI section; Home has none yet. If the model fails (guardrail, context window), the template answers instead. The answer is spoken only through VoiceOver until the announcement engine (3.3) lands. |
| T20 Test set & metrics | Deshna | #122 | Integrated; little data | `Evaluation/`, `TestSet/` | Live FPS/latency on the Live screen. The recorded set has 4 chair frames (T40); the other 10 scenarios are still to record. `swift test --filter recordedTestSet` scores it (T20 runner, #174). |

## Task status (T23–T45, second integration)

Merged into `cv-integration-2` on top of `computer_vision` at `8489803` (which includes the
direct commits for floor memory, the occupancy map, path clearance and "Take me to…").
Same caveat: none of this has been checked on a device by the integrator.

| Task | Owner | PR | Where | Notes |
|---|---|---|---|---|
| T23 Ask AI priorities | Nish | #176 | `AIPriorities.swift`, Settings | The user ranks hazards, navigation, people, signs, landmarks; the prompt and the answer's sentences follow that order. Close hazards still come first. Stacked on #175. |
| T24 Ask AI rules | Nish | #175 | `AskAIRules.swift` | Every answer (model or template) is cut to two sentences / 40 words, "can't tell" when nothing was found, a close hazard prepended, recent sentences not repeated, and safety claims removed. Integration fix: a negation only cancels a claim in its own clause ("There aren't any cars, so you can cross." is removed). |
| T26 Describe from Home | Deshna | #183 | `ARSceneAnalyzer.describeCurrentScene` | Starts the camera for up to 8 frames / 3 s when no camera screen is open, then stops it. |
| T27 Guidance kept alive | Rison | #186 | `ARSessionManager` (`GuidanceStatus`), `GuidanceStatusMonitor` | Screen stays awake while guidance runs. Silent on interruptions, "Camera guidance restored." when it returns, one automatic restart if relocalization fails within 5 s. |
| T32 Camera quality hints | Smitha | #178 | `CameraQualityEvaluator.swift`, `ImageSharpness.swift` | "Tilt your phone upward/downward", "Too dark", "Hold steady". Integration fix: normal priority, a problem must last 1 s, repeats at most every 10 s. Thresholds (±0.35 forward-Y, 250 lux, sharpness 4) need device tuning. |
| T33 Non-LiDAR distances | Rison | #188 | `GroundContactDistance.swift`, `ObjectSizePrior.swift`, `EstimatedDistance.swift` | Floor contact from ARKit feature points plus a height prior per class. `Detection.distanceAccuracy`; estimates are spoken "about 2 metres" and warnings band on the near end of the uncertainty. LiDAR devices are unchanged. |
| T34 Approaching objects | Rison | #189 | `MotionTracker.swift`, `ApproachAssessment.swift`, `ApproachAnnouncer.swift` | Least-squares velocity over 0.6 s, user motion removed, closest-approach time. "Stop." inside 1.5 s, a warning inside 3 s. Tune in a busy hallway: anyone passing within ~1 m counts. |
| T35 Crowds | Rison | #190 | `CrowdDetector.swift`, `CrowdAnnouncer.swift` | 3+ people within 2 m become one sentence in descriptions and an ambient mention at most every 15 s. |
| T36 Doors and windows | Deshna | #182 | `MeshFeatures.swift`, `StructuralFeatures.swift` | ARKit `meshWithClassification`, regrouped every 10th frame. Doors are described and (integration) found by "Take me to the door". Watch the mesh's battery and thermal cost. |
| T37 Street signals | Deshna | #184 | `StreetCrossing.swift`, `LumaSampler.swift` | Traffic lights and stop signs from YOLO; crosswalks from a stripe detector on the lower image, 3 of 5 frames to confirm, once per 20 s. Never says "safe". Check indoor false positives (striped floors, stair edges, blinds). |
| T38 Spoken camera questions | Nish | #177 | `VisualQuestion.swift`, `CommandViewModel` | Questions about what the camera sees go to Ask AI, the rest to the text assistant. Integration fix: asked with no camera screen open, Ask starts the camera for the question. |
| T39 Per-class thresholds | Smitha | #179 | `DetectionConfidencePolicy.swift` | 0.6 default, chairs at 0.55 (`DetectionConfidencePolicy.standard`). |
| T40 Test data | Smitha | #180 | `TestSet/`, `Evaluation/TestSet.swift` | 4 tape-measured chair frames with `conditions` tags; distance cases and calibration from recorded frames. `conditions` is a list of tags (#174 used an object; reconciled to the list). |
| T41 Elevation validation | Petr | #171 | `FieldTestRecorder`, camera screen (developer tools) | Setup and outcome records for the elevation field procedure below. |
| T45 Ask AI cancellation | Petr | #170 | `AskAI.swift` | Cancelling a question resumes once, including while Vision work is queued. |
| T20 runner | Nish | #174 | `Evaluation/TestSetEvaluation.swift` | Precision/recall overall, per scenario and per condition, distance error, detection time. |
| T31 Replace YOLO11 | Sahiti | #199 | `DFineObjectDetector.swift`, `ObjectDetector.swift` (`ObjectDetecting`) | Bundled model is now D-FINE-nano (Apache-2.0, `Peterande/D-FINE`, converted by `john-rocky/peaceofcake`); `yolo11n.mlpackage` removed. No built-in NMS, so it's a separate class behind a new `ObjectDetecting` protocol rather than a `modelName` swap on `ObjectDetector`, which stays as-is for a future NMS-included model. Picked after evaluating it and the full/tiny YOLOv3 (also Apple, MIT) headlessly with `coremltools` against three real COCO images — see "Known limitations" for the numbers and what was rejected. |

### Task descriptions that changed

- **T2** — "Expose scene depth and smoothed depth" → expose `sceneDepth` only, as a filtered `DepthMap`.
- **T5** — "Scale an RGB box into the depth map" → convert an upright box into sensor-orientation coordinates for the current interface orientation; the result is normalized depth-map coordinates.
- **T6** — "Per-pixel reliable-depth lookup" → build one filtered `DepthMap` per frame that every consumer reads.
- **T7** — Input is a normalized depth-map region and a `DepthMap`; output also feeds world position, bearing and the in-path test.
- **T8** — Folded into T20's distance evaluation; the affine calibration fit remains T8's contribution.
- **T15** — Output is `Detection.trackID`, not a `TrackedObject` list; image velocity deferred.
- **T16** — "Obstacle alert state machine" → "path announcement policy" producing `AnnouncementEvent`s about the state of the walking corridor (blocked at which band, which way round, clear), covering elevation hazards too.
- **T10** — adds `FloorMemory`: the fitted floor is carried across frames so the pipeline keeps working when the floor leaves the frame, which it does about 2 m from any wall.
- **T11** — adds shape naming and the clearance search (`assessPath`), the "local safe-path guidance" the handoff asked for.
- **T17** — Adds cadence limiting and de-duplication; runs outside the per-frame pipeline.
- **T18** — Input is `SceneObservation`; output capped to the most important items.
- **New: semantic–geometric fusion** — labelling geometric obstacles with recognized objects (`DetectionFusion.swift`). Done.
- **New: pipeline wiring (1.4)** — `AppServices.live` runs the analyzer on ARKit devices. Done.
- **New: "Take me to…" (`NavigationGuide.swift`)** — the user names a target ("the chair",
  "exit", "room 210") in the camera screen's Find mode and turns slowly on
  the spot. Every detection (T13/T14, geometric obstacles) and every sign (T17) now carries a
  `worldPosition`; signs are placed with the depth of the frame they were read from. A
  sighting that matches the request (label, text, or an everyday synonym such as "seat" or
  "someone") fixes the target in ARKit's world, and from then on the camera pose alone gives
  "Turn right. Chair is 3 metres away." / "Chair straight ahead, 2 metres." / "You have
  arrived." A full turn (340°) or 30 s without a sighting ends with "I couldn't find…".
  Instructions repeat every 4 s, change after 1.5 s, and are `.maneuver` events, so obstacle
  warnings still win. The target's position is the median of the last five sightings.
  Limits: the model knows COCO's 80 classes plus text, so "door" and "stairs" need ARKit mesh
  classification (next phase); a moving person is only as current as the last sighting.
- **New: orientation following** — the Live screen feeds the analyzer the phone's actual
  orientation. Held in landscape the horizontal field of view grows from about 50° to about
  70°, which is the most "see more" ARKit allows: world tracking and LiDAR `sceneDepth` are
  tied to the main wide camera, and `ARWorldTrackingConfiguration.supportedVideoFormats`
  offers no ultra-wide (0.5x) format — only face tracking does. A second capture session on
  the ultra-wide cannot run beside ARKit either.

## Known limitations

- **No device validation yet.** Everything below "Device validation" is unverified on hardware.
- **Non-LiDAR devices** get estimated distances for recognized objects and people (T33),
  but no geometric obstacles, occupancy map, path plan or kerbs: those need dense depth.
- **Object-detection model license (T31).** Resolved: the bundled model is now D-FINE-nano
  (Apache-2.0), not YOLO11n (AGPL-3.0). Picked after evaluating it and both full and Tiny
  YOLOv3 (Apple's own Core ML gallery, also MIT) headlessly with `coremltools` against three
  real COCO images, not just this project's one text-reading test photo — full YOLOv3 matched
  or beat D-FINE on accuracy but ran 5–6x slower and 11x larger on disk for it; YOLOv3-Tiny
  got close to D-FINE on speed/size but missed objects (a cat, a bear) D-FINE and YOLO11n both
  caught. D-FINE itself: ~8ms/frame on a Mac vs YOLO11n's ~3-4ms (still well inside T20's
  <100ms p95 budget) and 13MB vs 5.2MB on disk, for equal-or-better detections in that
  comparison. It has no NMS stage of its own (DETR-style: a fixed set of candidate boxes,
  trained not to duplicate one object) — `nonMaxSuppressed` in `DFineObjectDetector.swift` is
  a safety net, not load-bearing so far. T39's per-class thresholds (0.6, chairs 0.55) are
  carried over from YOLO11n untuned; it has not been checked against this model's own false-positive
  behavior on real data the way the line below describes for YOLO11n.
- **Model false positives.** On abstract wallpapers YOLO11n reported "spoon" (0.51) and
  "vase" (0.59) even at the 0.5 threshold. They are non-hazard classes, so they reach scene
  descriptions but not warnings. Tune the threshold, and possibly per class, with real data —
  this was never re-run against D-FINE (T31).
- **Portrait only in practice.** The Live and guidance screens set portrait orientation;
  other orientations are mapped correctly but not exercised.
- **Announcements are untested end to end on a device.** `AppServices.live` now runs
  Interaction's `AnnouncementEngine` (3.3) with `CoreHapticsRenderer` (3.2).
- **No obstacle warnings while the phone is locked or the app is in the background.** ARKit
  cannot run there. A trip's turns carry on, and the user is told "Camera paused. Obstacle
  warnings are off." when the session is interrupted.
- **Coverage that simply stops is not a drop-off in the live pipeline.** A fall with lower
  ground visible beyond the hole is reported, but `ElevationTuning.expectedMaxDistance` stays
  nil: a pitched-down camera and dark ground also end coverage early, so it would cry wolf.
- **Looping obstacle haptics stop after 3 s, or at "Path clear".** They mark a warning rather
  than following the obstacle's distance continuously.
- **Tracking is box-overlap only.** Fast lateral motion at a low analysis rate can split a
  track and repeat an announcement.
- **Thresholds are fixed** (3/2/1 m bands, 0.9 m corridor); `GuidanceProfile` cannot adjust them yet.
- **Detection boxes for geometric obstacles** assume a square footprint (depth is not measured).

## Device validation checklist

Run on a LiDAR iPhone (12 Pro or newer) from a debug build: Home → Camera guidance, with
the wrench in its toolbar on for readouts and recording:

1. T1: tracking reads "normal", camera ~60 fps, and the "move the phone" hint clears.
2. Analysis rate and latency (T20 line): target ≥ 10 fps and p95 under 100 ms in normal mode;
   check battery mode and after 10 minutes for thermal throttling.
3. Floor: camera height reads 1.1–1.5 m held at chest height (T10).
4. Distances: tape-measure a chair at 1, 2 and 3 m; record `DistanceTestCase`s and run
   `evaluateDistances` / `fitDistanceCalibration` (T7, T8).
5. Left/right: an object to the right is announced "on your right" (T9 handedness fix).
6. Fusion: a chair in the path is announced once as "Chair", not as "obstacle" plus "chair".
7. Announcements: walking toward a chair produces two announcements — "Chair ahead. Go
   left." at 2.5 m and "Stop. Chair ahead. Go left." at 1.2 m — no repeats while standing
   still (a reminder every 8 s at the stop band only) or when it flickers at the corridor
   edge, and one "Path clear." after stepping round it (T16). Sweep the phone left and right
   while stopped in front of it: the advice must not change.
8. Run the **Elevation field procedure** below before treating kerb, stair, ramp, or drop-off
   behavior as device-validated (T12, T16).
11. Wall: walk straight at a wall from 4 m. The readout switches from "Floor found" to
    "Floor remembered" around 2 m and the wall is still announced as "Wall", ending in
    "Stop. Wall ahead." Turn until the wall's end is in view and the advice becomes "Go left"
    or "Go right" (T10 memory, T11 kinds, clearance).
12. Doorway: walk toward an open door. The readout says "Narrow gap ahead" and no "Stop" is
    spoken while the gap is lined up.
13. Furniture: stand 1 m from an office chair or a table on a flat floor. The hazard lines
    stay empty — no "Drop-off at 0.4 m" or "Step up" from the legs (T12 exclusion).
14. Blocked: face a wall with open floor to one side. "Stop. Wall ahead. Turn left/right."
    names the open side; the readout says "Blocked — turn left/right".
15. Take me to: with a chair 3 m away behind you, tap "Take me to…", type "chair", turn
    slowly. Expect "Looking for chair. Turn slowly all the way around.", then within the
    turn "Turn left/right. Chair is 3 metres away.", "Chair straight ahead…", and "You have
    arrived." within a metre. Type "room 210" facing a room sign to test signs.
16. Landscape: turn the phone sideways on the Live screen. Boxes still land on objects and
    the readout keeps working; objects at the edges of the room appear sooner.
9. OCR: a room sign shows up in "Describe my surroundings" once, and disappears a few seconds
   after looking away (T17, T18).
10. No "delegate is retaining N ARFrames" warnings in the console (T3).

### Elevation field procedure (T41 — pending on-device execution)

This procedure has **not** been run by the repository maintainer. Run it only with a LiDAR
iPhone (12 Pro or newer), a sighted safety spotter, and a tape measure. Do not approach an
unprotected edge while relying on the app.

1. For each setup, measure and enter the physical setup name, surface material, edge distance,
   and expected vertical height in the camera screen's **Elevation test setup** controls
   (developer tools on, recording started). Start a
   recording, then tap **Record setup** before each approach.
2. Test a low curb up and down, standard stair risers in both directions, a compliant 1:12 ramp,
   and an abrupt protected drop-off. Include flat concrete/asphalt and a visually challenging
   surface where safe. Make at least three slow approaches per feature from 3–4 m.
3. For each pass, verify tracking is normal and note thermal state. The JSONL frame records keep
   tracking, thermal state, measured hazard distance/height, emitted events, and actually
   delivered events. Tap **Record outcome** as `tester heard warning`, `warning missing`, `wrong
   warning`, `false warning`, or `inconclusive` after the pass.
4. Run controls: the ramp must not become a step; an object, chair leg, or low box on level
   ground must not become a surface hazard; ordinary sparse or missing-depth frames must not be
   called a drop-off. Interior coverage holes remain ambiguous, never safe.
5. Confirm a detected close drop-off yields `Stop. Drop-off ahead.` with critical priority, while
   an equivalently close curb/step is high priority. Confirm the delivered-event record agrees
   with the on-screen banner/audio outcome.
6. Repeat after a sustained run to capture fair/serious thermal conditions if they occur. Export
   the JSONL file from `Documents/FieldTests/` and compare tape-measured values to the recorded
   `HazardRecord` values before proposing any threshold change.

`expectedMaxDistance` intentionally remains unset in the live elevation pipeline. The walking
corridor range is an application look-ahead preference, not proof that LiDAR should return depth
that far; using it would turn ordinary sparse frames into false urgent drop-offs. The detector's
missing-depth drop-off mode is covered by explicit synthetic tests only until field recordings
support a reliable coverage model.

Elevation JSONL records use five kinds: `frame`, `delivered`, `mark`, `elevationSetup`, and
`elevationOutcome`. Each elevation setup receives a UUID `scenarioID`; its outcome includes the
same immutable setup, and every analyzed frame and delivered announcement while it is active
contains `elevationScenarioID`. Emitted-event IDs preserve that association if delivery happens
after closure. Calibration tooling must group only records with the same ID. An outcome requires
at least one queued frame and closes the scenario, so later frames/events cannot contaminate that
pass. `outcome` is the tester's observation; `deliveredEventCount` is separate machine-recorded
delivery evidence available before the outcome. Setup entry requires a nonempty physical setup
and surface plus finite, nonnegative tape-measured expected height and distance.

## Next phase

- **Phone pose check** — use the camera pitch from the pose to tell the user when the camera
  points at the floor or sky. The handoff document calls for it; no task covers it.
- **Occupancy map, next steps** — the map is 2-D and forgets nothing until seen through, so
  a person who stood still for a while leaves a mark until the floor behind them is seen
  again; add a slow decay for cells not re-observed. ARKit's scene mesh could seed the map
  with classified walls and doors. Show the map on the Live screen for sighted testers.
- **T19 Ask AI on device** — check answers and latency on a real iPhone, with and without
  Apple Intelligence; add an Ask AI entry point to Home. Then **T21–T24** (AI modes,
  personalization, safety rules), outside the obstacle pipeline.
- **Motion** — track velocity and approach rate for people and moving objects (deferred from T15).
- **Recorded test set** — capture and annotate the eleven T20 scenarios; run detection and
  distance evaluation on every model or threshold change.
- **D-FINE on device (T31)** — check real accuracy, speed and false-positive rate on an
  iPhone; the evaluation so far is headless (`coremltools` on a Mac, three stock COCO
  images), not the recorded test set, which has only 4 chair frames so far (T40). Re-tune
  T39's thresholds against that, not carried over from YOLO11n untouched.
- **Profile-driven thresholds** — let `GuidanceProfile` set announcement bands and verbosity.
- **ARKit mesh classification** (`Detection.Origin.mesh`, `PerformanceMode.meshReconstructionEnabled`)
  is reserved in the contracts but unused.

## Testing

```bash
swift test --scratch-path /tmp/accessable-build
```

233 tests in 33 suites cover everything in `Models/Vision` and the shared phrasing, including
the T5 orientation mapping against Vision for all eight orientations, T6 filtering on real
pixel buffers, T13 and T17 against the bundled test image, the T16 announcement rules, the
floor memory, the occupancy map (hits, rays, clearing, recentring), the planner on it, a
wall found with no floor in view, and the navigation guide (matching, scanning, steering
from pose, arrival, giving up).
`Models/Services/Vision` is covered by the iOS build and the device checklist above.
