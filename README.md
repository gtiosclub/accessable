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
    │   │   └── Broadcaster.swift        one-to-many AsyncStream helper (latest value by default)
    │   └── Formatting/
    │       └── SpokenPhrasing.swift     shared speech rules ("about 2 metres", "on your left")
    ├── ViewModels/                      @MainActor @Observable classes. No SwiftUI imports.
    │   ├── AppViewModel.swift           app-wide state (profile, onboarding, services)
    │   ├── HomeViewModel.swift          reference example of the view model pattern
    │   ├── Vision/                      Subteam 1 — Computer Vision
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
