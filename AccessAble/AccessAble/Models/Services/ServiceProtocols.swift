import Foundation

// The interfaces between subteams. Each subteam implements its own protocol(s) and only
// talks to the others through these. Placeholder implementations live in PlaceholderServices.swift
// so every branch builds and previews before the real implementations land.

// MARK: - User Interaction (3.3) — owns delivery of everything the user hears/feels

/// Anything that wants to tell the user something submits an event here. CV and Maps depend only on this.
protocol AnnouncementSink: Sendable {
    func submit(_ event: AnnouncementEvent) async
}

/// The full announcement engine: priority queue, dedup, rate limiting, repeat-last, pause.
protocol AnnouncementEngineProtocol: AnnouncementSink {
    /// Events as they are actually delivered (after filtering/dedup). UI uses this for the visual banner.
    func deliveredEvents() -> AsyncStream<AnnouncementEvent>
    func repeatLast() async
    func pause() async
    func resume() async
    func updateProfile(_ profile: GuidanceProfile) async
}

/// Renders a haptic from the shared vocabulary (3.2).
protocol HapticRendering: Sendable {
    func play(_ id: HapticID, intensity: Float) async
}

/// Publishes the current PerformanceMode (3.3). CV (1.4) and Maps (2.1) subscribe.
protocol PerformanceModeProviding: Sendable {
    func modes() -> AsyncStream<PerformanceMode>
}

// MARK: - Computer Vision (1.x)

protocol SceneObservationProviding: Sendable {
    /// Latest-only stream of analyzed frames.
    func observations() -> AsyncStream<SceneObservation>
    func start() async throws
    func stop() async
}

/// "Describe my surroundings" / "Ask AI" / sign reading (1.3).
protocol SceneDescribing: Sendable {
    /// Tier A: instant, offline, template-based.
    func describeCurrentScene() async -> String
    /// Tier B: still frame + question to an on-device or cloud model.
    func ask(_ question: String, locationContext: String?) async throws -> String
}

// MARK: - Maps + Location (2.x)

/// Tracking runs while any stream has a subscriber, so ending a trip stops it. Location and heading streams
/// stay silent without permission and drop invalid readings. Publish through `Broadcaster`; it doesn't report
/// when its last subscriber leaves, so count subscribers yourself.
protocol LocationProvider: Sendable {
    func locationSamples() -> AsyncStream<LocationSample>
    func headingSamples() -> AsyncStream<HeadingSample>
    /// Emits the current permission immediately, then every change.
    func authorizationStates() -> AsyncStream<LocationAuthorization>
    /// Prompts for When In Use access if undetermined. Returns immediately; the result arrives on
    /// `authorizationStates()`.
    func requestAuthorization() async
}

/// Computes a route without starting navigation or delivering speech.
protocol RoutingService: Sendable {
    /// - Throws: `RoutingError`, or `CancellationError` if the task is cancelled.
    func route(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async throws -> NavigationRoute
}

protocol TripStateProviding: Sendable {
    func tripStates() -> AsyncStream<TripState>
    func pauseTrip() async
    func resumeTrip() async
    func endTrip() async
}

/// Short spoken description of where the user is, e.g. "on Ferst Drive facing north".
/// Used by "Where am I" and added to Ask AI prompts.
protocol LocationContextProviding: Sendable {
    func currentLocationDescription() async -> String?
}
