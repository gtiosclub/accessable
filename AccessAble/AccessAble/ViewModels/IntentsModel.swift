//
//  IntentsModel.swift
//  AccessAble
//
//  Created by Ria Sharma on 10/13/26.
//

import AppIntents
import Observation

// Screens a shortcut can open.
enum AppDestination: Hashable {
    case scene   // "Camera guidance"
    case trip    // "Trip"
}

// Shared bridge between App Intents and the UI.
@MainActor
@Observable
final class IntentsModel {
    static let shared = IntentsModel()
    var pending: AppDestination?  // set by intents that open a screen
    var describeRequested = false // set by the "describe surroundings" intent
    private init() {}
}

// Intents
// 1) "Describe Surroundings" intent and description
struct DescribeSurroundingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Describe My Surroundings"
    static let description = IntentDescription("Speaks what the camera sees, nearest hazards first.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentsModel.shared.describeRequested = true
        return .result()
    }
}

// 2) "Camera Guidance" intent and description
struct OpenCameraGuidanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Camera Guidance"
    static let description = IntentDescription("Announces obstacles as you walk.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentsModel.shared.pending = .scene
        return .result()
    }
}

// 3) "Trip" intent and description
struct OpenTripIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Trip"
    static let description = IntentDescription("Plan or continue a walking trip.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentsModel.shared.pending = .trip
        return .result()
    }
}

// Shortcuts provider
struct AccessAbleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DescribeSurroundingsIntent(),
            phrases: [
                "Describe my surroundings in \(.applicationName)",
                "Tell me what's around me with \(.applicationName)"
            ],
            shortTitle: "Describe Surroundings",
            systemImageName: "eye"
        )
        AppShortcut(
            intent: OpenCameraGuidanceIntent(),
            phrases: [
                "Open camera guidance in \(.applicationName)",
                "Open camera in \(.applicationName)"
            ],
            shortTitle: "Camera Guidance",
            systemImageName: "camera.viewfinder"
        )
        AppShortcut(
            intent: OpenTripIntent(),
            phrases: [
                "Open trip in \(.applicationName)",
                "Open my trip in \(.applicationName)"
            ],
            shortTitle: "Trip",
            systemImageName: "figure.walk"
        )
    }
}
