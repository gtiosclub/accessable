import CoreGraphics
import Foundation
import os

// Stand-in implementations of every protocol in ServiceProtocols.swift.
// They let the app run and SwiftUI previews render before the real services exist.
// Subteams: replace the matching entry in `AppServices.live` when your implementation is ready,
// and keep these around for previews and unit tests.

private let log = Logger(subsystem: "AccessAble", category: "Placeholder")

/// Logs events and republishes them; no priority queue or speech. Replaced by 3.3.
actor PlaceholderAnnouncementEngine: AnnouncementEngineProtocol {
    private nonisolated let delivered = Broadcaster<AnnouncementEvent>()
    private var profile: GuidanceProfile = .default
    private var isPaused = false
    private var last: AnnouncementEvent?

    func submit(_ event: AnnouncementEvent) async {
        guard !isPaused, profile.allows(event), !event.isExpired() else { return }
        log.info("[\(event.category.rawValue)/\(event.priority.rawValue)] \(event.text)")
        last = event
        delivered.send(event)
    }

    nonisolated func deliveredEvents() -> AsyncStream<AnnouncementEvent> {
        delivered.stream(bufferingPolicy: .bufferingNewest(8))
    }

    func repeatLast() async {
        if let last { delivered.send(last) }
    }

    func pause() async { isPaused = true }
    func resume() async { isPaused = false }
    func updateProfile(_ profile: GuidanceProfile) async { self.profile = profile }
}

struct PlaceholderHaptics: HapticRendering {
    func play(_ id: HapticID, intensity: Float) async {
        log.info("haptic \(id.rawValue) @ \(intensity)")
    }
}

/// Emits one hard-coded scene so UI work can proceed without a camera.
struct PlaceholderSceneProvider: SceneObservationProviding, SceneDescribing {
    static let sample = SceneObservation(
        detections: [
            Detection(label: "person", confidence: 0.9, boundingBox: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.5),
                      distance: 2.0, bearing: .ahead, origin: .model, isHazard: true),
            Detection(label: "chair", confidence: 0.8, boundingBox: CGRect(x: 0.05, y: 0.5, width: 0.2, height: 0.3),
                      distance: 1.0, bearing: RelativeBearing(degrees: -60), origin: .model, isHazard: true),
            Detection(label: "door", confidence: 0.7, boundingBox: CGRect(x: 0.45, y: 0.1, width: 0.15, height: 0.6),
                      distance: 4.0, bearing: .ahead, origin: .mesh, isHazard: false),
        ],
        ground: .sidewalk,
        hasMetricDepth: true
    )

    func observations() -> AsyncStream<SceneObservation> {
        AsyncStream { continuation in
            continuation.yield(Self.sample)
            continuation.finish()
        }
    }

    func start() async throws {}
    func stop() async {}

    func describeCurrentScene() async -> String {
        Self.sample.prioritizedDetections.map(SpokenPhrasing.describe).joined(separator: " ")
    }

    func ask(_ question: String, locationContext: String?) async throws -> String {
        "Ask AI is not available yet."
    }
}

struct PlaceholderTripProvider: TripStateProviding, LocationContextProviding {
    func tripStates() -> AsyncStream<TripState> {
        AsyncStream { continuation in
            continuation.yield(.idle)
            continuation.finish()
        }
    }

    func pauseTrip() async {}
    func resumeTrip() async {}
    func endTrip() async {}

    func currentLocationDescription() async -> String? { nil }
}
