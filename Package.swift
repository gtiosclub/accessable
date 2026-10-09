// swift-tools-version: 6.0
import PackageDescription

// Test harness for the Computer Vision geometry modules (1.1 / tasks T10-T12, T14).
//
// This package exists ONLY so `swift test` can exercise the algorithms headlessly on a
// Mac. It compiles the same source files the app target does — it is not a dependency of
// the app, and the app does not know it exists. The Xcode project picks those files up
// through its synchronized folder group as usual.
//
// It lives at the repo root rather than next to the sources because SwiftPM refuses target
// paths outside the package root.
let package = Package(
    name: "SceneGeometry",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SceneGeometry",
            path: "AccessAble/AccessAble/Models",
            // Everything the app has that these modules don't need. Listed so SwiftPM
            // stops warning about files it can see but isn't compiling.
            exclude: [
                "Services",
                "Formatting",
                "Core/AnnouncementEvent.swift",
                "Core/GuidanceProfile.swift",
                "Core/HapticID.swift",
                "Core/PerformanceMode.swift",
                "Core/TripState.swift",
            ],
            sources: [
                "Vision",
                "Core/SceneObservation.swift",
                "Core/RelativeBearing.swift",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SceneGeometryTests",
            dependencies: ["SceneGeometry"],
            path: "Tests/SceneGeometryTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
