import Foundation

// The interfaces between subteams. Each subteam implements its own protocol(s) and only
// talks to the others through these. Placeholder implementations live in PlaceholderServices.swift
// so every branch builds and previews before the real implementations land.

// MARK: - User Interaction (3.3) — owns delivery of everything the user hears/feels

/// Natural-language commands and questions (3.1). Text in; a command, or a spoken answer, out.
protocol CommandInterpreting: Sendable {
    /// Never throws: anything it can't understand comes back as `.unknown`.
    func interpret(_ text: String) async -> VoiceCommand
    /// Short answer suitable for speech. `context` is e.g. "on Ferst Drive facing north".
    func answer(_ question: String, context: String?) async throws -> String
}


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
    func setInCall(_ inCall: Bool) async
}

/// Renders a haptic from the shared vocabulary (3.2).
protocol HapticRendering: Sendable {
    func play(_ id: HapticID, intensity: Float) async
    func stop() async
}

/// Publishes the current PerformanceMode (3.3). CV (1.4) and Maps (2.1) subscribe.
protocol PerformanceModeProviding: Sendable {
    func modes() -> AsyncStream<PerformanceMode>
}

// MARK: - Computer Vision (1.x)

protocol SceneObservationProviding: Sendable {
    /// Latest-only stream of analyzed frames.
    func observations() -> AsyncStream<SceneObservation>
    /// Calls nest, because features share the one camera: it keeps running until every
    /// successful `start()` has had its `stop()`. Don't call `stop()` after a `start()` that threw.
    func start() async throws
    func stop() async
}

/// Landmarks for Maps to match to the route (LAND-1): CV detects, Maps matches. Silent while the camera is off.
/// Each landmark is sent once it is confirmed (for signs, once `SignAnnouncer`'s reads agree), not every frame.
protocol LandmarkObserving: Sendable {
    func landmarkObservations() -> AsyncStream<LandmarkObservation>
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

/// Main actor because MKLocalSearchCompleter is.
@MainActor
protocol DestinationSearching: Sendable {
    func suggestions() -> AsyncStream<Result<[SearchSuggestion], DestinationSearchError>>
    func update(query: String)
    func resolve(_ suggestion: SearchSuggestion) async throws -> Destination
}

protocol TripStateProviding: Sendable {
    func tripStates() -> AsyncStream<TripState>
    /// The route the trip is following, replaced on each reroute; nil when no trip is running. Kept out of
    /// `TripState` so the Live Activity's state stays small.
    func tripRoutes() -> AsyncStream<NavigationRoute?>
    /// Starts guidance along `route`, replacing any trip in progress. Progress arrives on `tripStates()`.
    /// Voice "start trip" needs a planned route first; a future `planTrip`/`startTrip()` split is expected.
    func startTrip(route: NavigationRoute, destination: Destination) async
    func pauseTrip() async
    func resumeTrip() async
    func endTrip() async
    /// A new route from where the user is now, for a running trip, when they ask for one.
    func reroute() async
}

/// The trip's Live Activity on the lock screen and in the Dynamic Island; one at a time.
protocol TripActivityClient: Sendable {
    /// Throws `TripActivityStartError.activitiesDisabled` when the user has turned Live Activities off,
    /// `.notInForeground` when the app isn't on screen, or the system's error when it refuses one.
    /// After `staleDate`, unless an update comes first, the widget says guidance isn't updating; nil never goes stale.
    func start(
        _ attributes: TripActivityAttributes, state: TripActivityAttributes.ContentState, staleDate: Date?
    ) async throws
    func update(_ state: TripActivityAttributes.ContentState, staleDate: Date?) async
    /// `immediately` removes it from the lock screen now; otherwise it stays a few minutes so the final
    /// state can be read, until an immediate end.
    func end(_ state: TripActivityAttributes.ContentState, immediately: Bool) async
    /// Removes every trip activity, including any left by an earlier launch that ended mid-trip.
    func endAll() async
}

/// Caught by name and logged, never shown to the user.
enum TripActivityStartError: Error {
    case activitiesDisabled
    /// A Live Activity can only be started while the app is on screen.
    case notInForeground
}

/// Short spoken description of where the user is, e.g. "on Ferst Drive facing north".
/// Used by "Where am I" and added to Ask AI prompts.
protocol LocationContextProviding: Sendable {
    func currentLocationDescription() async -> String?
}

protocol AuthService: Sendable {
    func userChanges() -> AsyncStream<AuthUser?>
    func currentUser() async -> AuthUser?
    func signIn(email: String, password: String) async throws -> AuthUser
    func createAccount(email: String, password: String) async throws -> AuthUser
    func signOut() async throws
    func idToken() async throws -> String
}

extension AuthService {
    /// Stand-ins have no real sign-in to prove.
    func idToken() async throws -> String { throw AuthError.unknown }
}

// MARK: - Calls (MATCH-x)
// See Docs/Calls/Overview.md for what "online" means and who owns the camera during a call.
// Sign-in comes from `AuthService` (shared with REPORT, defined above); the call services reuse it
// rather than defining their own.

/// Who can be called right now.
protocol VolunteerDirectory: Sendable {
    /// Volunteers that are reachable now (Online toggle on and a recent `lastSeen`), replaced on each change.
    func allVolunteers() -> AsyncStream<[Volunteer]>
    func onlineVolunteers() -> AsyncStream<[Volunteer]>
}

/// The signed-in volunteer's own availability.
protocol PresenceService: Sendable {
    /// Emits the current value immediately, then every change.
    func onlineStates() -> AsyncStream<Bool>
    /// Turns the Online toggle on or off. While on and the app is on screen, the implementation
    /// refreshes `lastSeen` about every 30 seconds.
    func setOnline(_ isOnline: Bool) async throws
}

/// Volunteer-side read model. Cancel the stream when the app is no longer on screen.
/// Nil dismisses a withdrawn/ended ring. Errors must not silently become a missing call.
protocol IncomingCallProviding: Sendable {
    @MainActor
    func incomingCalls(volunteerID: String) -> AsyncThrowingStream<IncomingCall?, Error>
}

/// What a caller hears while `requestCall` works (VOLUNTEER-7).
enum CallRequestProgress: Equatable, Sendable {
    enum Miss: Equatable, Sendable { case noAnswer, declined }
    /// Ringing a volunteer; `attempt` counts from 1.
    case ringing(attempt: Int)
    /// The last volunteer declined or didn't answer in 30 seconds; the next one is about to ring.
    case tryingNext(after: Miss)
}

/// Matching (VOLUNTEER-6): the caller's app rings one volunteer at a time as Firestore transactions,
/// and firestore.rules enforce every step. Tickets come only from the getCallToken Worker.
protocol CallSignaling: Sendable {
    /// Caller: rings online volunteers one at a time (`volunteerID` first, if given) until one accepts,
    /// then returns the ticket. A decline or 30 seconds moves on to the next volunteer, reported on `progress`.
    func requestCall(
        preferring volunteerID: String?,
        progress: @Sendable (CallRequestProgress) -> Void
    ) async throws -> CallTicket
    /// Volunteer: answers a call that's ringing them. Throws if it was taken or ended.
    func accept(callID: String) async throws -> CallTicket
    /// Volunteer: turns down a call that's ringing them.
    func decline(callID: String) async throws
    /// Caller: stops ringing this volunteer. Fails if they already picked up.
    func skip(callID: String) async throws
    /// Either side: hangs up, or gives up while it's still ringing.
    func endCall(callID: String) async
}

/// The live video call. While connected it owns the camera: `ARSessionManager` pauses, CV and AR
/// geo-tracking pause with it, and all resume when the call ends.
protocol VideoCallSession: Sendable {
    func states() -> AsyncStream<CallState>
       func connect(with ticket: CallTicket) async throws
       func disconnect() async
       /// Mutes or unmutes this phone's microphone.
       func setMicrophoneMuted(_ muted: Bool) async throws
       /// Switches between the back and front camera. Calls start on the back camera.
       func flipCamera() async throws
       /// Turns the back camera's light on or off. Throws when the current camera has no light.
       func setFlashlight(_ on: Bool) async throws
}

// MARK: - Signed-in account profiles (VOLUNTEER-2)

/// Uses the same AuthUser.id as REPORT. A missing document means onboarding is needed;
/// a failed read must throw, so a network/permission error never resets a user's role.
protocol UserProfileStore: Sendable {
    func load(userID: String) async throws -> UserProfile?
    func save(userID: String, role: UserRole, displayName: String,
              languages: [String]) async throws -> UserProfile
}
