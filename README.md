# accessable
GT iOS Club Fall 2026 - AccessAble app

## Project layout (MVVM)

```
AccessAble/                              Xcode project folder
├── AccessAble.xcodeproj                 open this
├── Info.plist                           usage strings + background modes (merged with the generated plist)
└── AccessAble/                          all app source (synced folder: new files are added automatically)
    ├── AccessAbleApp.swift              @main entry point
    ├── PrivacyInfo.xcprivacy            privacy manifest
    ├── Assets.xcassets
    ├── Models/                          plain data + services. No SwiftUI imports.
    │   ├── Core/                        Phase 0 shared contracts. Changes need a review from all three subteams.
    │   │   ├── AnnouncementEvent.swift  category, priority, text, HapticID, bearing, source, expiresAt, dedupKey
    │   │   ├── GuidanceProfile.swift    vision level, channels, verbosity, speech rate, haptic intensity, categories
    │   │   ├── HapticID.swift           haptic vocabulary v1 (one AHAP file per case)
    │   │   ├── TripState.swift          trip phase, next maneuver, distances, GeoCoordinate
    │   │   ├── SceneObservation.swift   detections, ground surface, recognized text
    │   │   ├── PerformanceMode.swift    normal / battery
    │   │   └── RelativeBearing.swift    direction relative to the user's facing
    │   ├── Services/
    │   │   ├── ServiceProtocols.swift   the interfaces between subteams
    │   │   ├── AppServices.swift        dependency container; swap placeholders for real services here
    │   │   ├── PlaceholderServices.swift  stand-ins so the app builds and previews on day one
    │   │   ├── PerformanceModeMonitor.swift  Low Power Mode + thermal → PerformanceMode
    │   │   ├── Broadcaster.swift        one-to-many AsyncStream helper (latest value by default)
    │   │   └── ARSceneAnalyzer.swift    ARKit session driving the 1.1 detectors (needs a device)
    │   ├── Formatting/
    │   │   └── SpokenPhrasing.swift     shared speech rules ("about 2 metres", "on your left")
    │   └── Vision/                      Subteam 1 — Computer Vision detectors
    │       ├── Plane3D.swift            a plane + signed distanceFromPlane()
    │       ├── DepthPointCloud.swift    depth map → world point cloud (ARKit-free)
    │       ├── GroundProfiler.swift     point cloud → [GroundSample] for T12
    │       ├── BoundingBoxLayout.swift  normalized box → aspect fill/fit preview rect
    │       ├── FloorPlaneDetector.swift RANSAC floor fit from a point cloud (T10)
    │       ├── WalkingCorridor.swift    the strip of space ahead of the user
    │       ├── GeometricObstacle.swift  one thing standing up off the floor
    │       ├── GeometricObstacleDetector.swift  obstacles by geometry, no labels (T11)
    │       ├── GroundSample.swift       one height reading of the surface ahead
    │       ├── ElevationHazard.swift    stepUp / stepDown / dropOff / unknown
    │       ├── ElevationHazardDetector.swift  curbs, steps and drop-offs (T12)
    │       ├── PeopleDetection.swift    Vision → Detection conversion, no Vision import
    │       └── PeopleDetector.swift     VNDetectHumanRectanglesRequest (T14)
    ├── ViewModels/                      @MainActor @Observable classes. No SwiftUI imports.
    │   ├── AppViewModel.swift           app-wide state (profile, onboarding, services)
    │   ├── HomeViewModel.swift          reference example of the view model pattern
    │   ├── Vision/                      Subteam 1 — Computer Vision
    │   │   ├── LiveSceneViewModel.swift owns its own ARSceneAnalyzer, not services.scene
    │   │   └── PhotoDetectionViewModel.swift  T14 against a still image (works in the Simulator)
    │   ├── Maps/                        Subteam 2 — Maps + Location
    │   └── Interaction/                 Subteam 3 — User Interaction
    └── Views/                           SwiftUI only. No business logic.
        ├── RootView.swift, HomeView.swift
        ├── Components/                  shared accessible building blocks
        └── Vision/  Maps/  Interaction/
```

## Conventions

- **Models** are value types (`struct`/`enum`), `Sendable`, and `Codable` where they get persisted. Services
  (camera, location, announcement engine) also live under `Models/Services`, behind a protocol.
- **ViewModels** are `@MainActor @Observable final class`. They take `AppServices` (or `AppViewModel`) in `init`
  and depend only on protocols. Long-running subscriptions go in `func start() async`.
- **Views** own their view model with `@State`, call `.task { await viewModel.start() }`, and forward actions to the view model.
  See `HomeView` + `HomeViewModel` for the reference example.
- **Cross-team communication only goes through `ServiceProtocols.swift`.** CV and Maps never speak or buzz directly;
  they submit an `AnnouncementEvent` to `services.announcements`, and the engine (3.3) decides what to say.
- Put your subteam's files in your subteam's subfolder (`Vision/`, `Maps/`, `Interaction/`) inside each of the
  three layers. That keeps merge conflicts between branches low.
- When your real service is ready, replace the matching `Placeholder…` in `AppServices.live`. Keep the placeholder
  for previews and tests.

## Testing the geometry modules

`Models/Vision/` holds pure algorithms, so they are tested on the Mac rather than in a
simulator. `Package.swift` at the repo root is a test-only SwiftPM harness that compiles
the same source files the app target does — it is not a dependency of the app, and the
Xcode project does not know it exists.

```bash
swift test --scratch-path /tmp/accessable-build
```

The `--scratch-path` is not optional here. This repo sits under `~/Documents`, which
iCloud Drive syncs, and the sync daemon stamps `com.apple.FinderInfo` onto the freshly
built `.xctest` bundle — which makes `codesign` fail with *"resource fork, Finder
information, or similar detritus not allowed"*. Building outside the synced tree sidesteps
it. A plain `swift test` works if you move the repo somewhere iCloud does not touch.

It lives at the repo root because SwiftPM refuses target paths outside the package root.
When you add a file to `Models/Vision/`, the Xcode target picks it up through the
synchronized folder group automatically; the package picks it up too, since it compiles the
whole `Vision` directory.

## Seeing the detectors run

Home → **Live detection** opens `LiveSceneView`: the ARKit camera feed with boxes drawn
over it (green = people from Vision, orange = geometric obstacles) plus a readout of the
fitted floor and any kerbs or drop-offs ahead.

It needs a **physical device** — ARKit world tracking does not run in the Simulator — and
a **LiDAR device** (iPhone 12 Pro or newer) for the floor, obstacle and kerb readouts.
In the Simulator the screen says so and offers **Detect people in a photo** instead, which
runs the real Vision request over a photo from the library and draws the boxes it returns.
That is T14's own acceptance path ("test against saved images or videos") and the only
part of this that can be checked without hardware.
Without LiDAR you still get people boxes, `hasMetricDepth` stays false, and the geometry
readouts stay empty; that is the non-LiDAR fallback the shared contract already describes.

This screen owns its own `ARSceneAnalyzer` rather than reading `services.scene`, so
`AppServices.live` still uses `PlaceholderSceneProvider` and nothing else in the app
changes. Swapping the placeholder for the real provider is task 1.4.

## Accessibility baseline (every PR)

- Every control has a label, a hint where the action isn't obvious, and correct traits (`.accessibleControl(...)`).
- Hit targets are at least 44×44 pt (`.minimumTapTarget()`).
- Text uses Dynamic Type styles and works at accessibility sizes. No fixed font sizes.
- Icons that duplicate text are `.accessibilityHidden(true)`.
- Test the screen with VoiceOver on (and Screen Curtain) before opening a PR.

## Xcode setup

Open `AccessAble/AccessAble.xcodeproj`. Settings the code depends on (already set in the project, don't change them):

- iOS Deployment Target **26.2**, Swift Language Version **6**.
- **Default Actor Isolation: nonisolated** (the Xcode template default is MainActor). View models are marked
  `@MainActor` explicitly; models and services must stay off the main actor so camera/LiDAR processing doesn't block the UI.
- `INFOPLIST_FILE = Info.plist` with `GENERATE_INFOPLIST_FILE = YES`. Add new usage strings to `AccessAble/Info.plist`.
  Keep it outside the inner `AccessAble/` source folder, or Xcode will also copy it as a resource and the build fails.
- Only files that belong in the app go inside the inner `AccessAble/` folder — anything there (including docs) is bundled.
