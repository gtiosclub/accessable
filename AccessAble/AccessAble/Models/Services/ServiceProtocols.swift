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
    /// Delivered events once they have been said, or cut off, so a listener can wait for the end of speech. An event
    /// dropped before delivery never comes.
    func finishedEvents() -> AsyncStream<FinishedAnnouncement>
    func repeatLast() async
    func pause() async
    func resume() async
    func updateProfile(_ profile: GuidanceProfile) async
    func setInCall(_ inCall: Bool) async
}

/// An announcement whose speech has ended.
struct FinishedAnnouncement: Equatable, Sendable {
    let id: UUID
    /// Cut off, by a more urgent announcement or a pause, rather than said to the end.
    let wasInterrupted: Bool
    /// Nothing else was waiting to be said.
    let isIdle: Bool
}

extension AnnouncementEngineProtocol {
    /// Ends at once, for engines that don't speak, so a listener goes on without waiting.
    func finishedEvents() -> AsyncStream<FinishedAnnouncement> {
        AsyncStream { $0.finish() }
    }
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

/// The phone's battery, read for the low-battery warnings on a trip.
protocol BatteryReading: Sendable {
    func status() async -> BatteryStatus
    /// Lets the system stop tracking the battery until the next `status()`.
    func stopReading() async
}

struct BatteryStatus: Equatable, Sendable {
    /// From 0 to 1; nil when the system doesn't know it.
    let level: Float?
    /// Plugged in, so a low level isn't worth warning about.
    let isChargingOrFull: Bool
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
    /// - Parameters:
    ///   - preferences: The preferences `route` was found with. Every reroute this trip uses them, even if the user's
    ///     settings change meanwhile.
    ///   - resumingAtStep: For a trip resumed after the app closed, the step of `route` that was next, so the trip
    ///     places the user along the route from their first fix rather than at its start; nil starts at the start.
    func startTrip(route: NavigationRoute, destination: Destination, preferences: RoutePreferences,
                   resumingAtStep: Int?) async
    func pauseTrip() async
    func resumeTrip() async
    func endTrip() async
    /// A new route from where the user is now, for a running trip, when they ask for one.
    func reroute() async
    /// Someone else's report the user has just walked past, to ask whether it is still there; once a report a trip,
    /// and only as it happens: a new subscriber hears none from before.
    func reportQuestions() -> AsyncStream<ReportQuestion>
    /// The active reports near the trip's route, the user's own included, to show on the map: on each report snapshot
    /// and route change, and empty from the start and end of each trip. A new subscriber hears the latest.
    func mapReports() -> AsyncStream<[Report]>
    /// The screen is done with the question about `reportID`. The next question waits for this.
    func reportQuestionEnded(_ reportID: String, outcome: ReportQuestionOutcome) async
}

extension TripStateProviding {
    func reportQuestions() -> AsyncStream<ReportQuestion> {
        AsyncStream { $0.finish() }
    }

    func mapReports() -> AsyncStream<[Report]> {
        AsyncStream { $0.finish() }
    }
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

/// Stores community reports and streams changes in the requested area.
protocol ReportService: Sendable {
    func submit(_ report: Report) async throws
    func reports(near coordinate: GeoCoordinate, radius: Double) async throws -> [Report]
    /// The signed-in user's one vote on someone else's report: a "yes" moves its expiry to one lifetime from now,
    /// never earlier, and the second "no" since the last "yes" ends it now. Returns whether the expiry moved later.
    /// - Throws: `ReportServiceError`: `.notSignedIn`; `.rateLimited` within a minute of their last vote;
    ///   `.permissionDenied` for their own report, a second vote, an expired report, or a "no" on a report under
    ///   ten minutes old; `.unavailable` when the server can't be reached in time.
    @discardableResult
    func confirm(_ reportID: String, isStillPresent: Bool) async throws -> Bool
    func reportChanges(near coordinate: GeoCoordinate, radius: Double) -> AsyncStream<[Report]>
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
    func refreshProfile() async throws
}

extension PresenceService {
    func refreshProfile() async throws {} // In-memory/test services have no separate directory copy.
}

/// Volunteer-side read model. Cancel the stream when the app is no longer on screen.
/// Nil dismisses a withdrawn/ended ring. Errors must not silently become a missing call.
protocol IncomingCallProviding: Sendable {
    @MainActor
    func incomingCalls(volunteerID: String) -> AsyncThrowingStream<IncomingCall?, Error>
}


/// Text chat between a caller and one volunteer (CHAT-1). firestore.rules decide who may write.
protocol ChatService: Sendable {
    func currentUserID() async -> String?
    /// The chat's messages, oldest first, replaced on each change. Works before the chat exists.
    func messages(chatID: String) -> AsyncThrowingStream<[ChatMessage], Error>
    /// Sends from the signed-in user. A caller's first message starts the chat.
    func send(_ text: String, chatID: String) async throws
    /// The signed-in volunteer's chats, most recent first.
    func volunteerChats() -> AsyncThrowingStream<[ChatThread], Error>
}

protocol CallSafetyService: Sendable {
    func hasConsent() async throws -> Bool
    func acceptConsent() async throws
    func report(callID: String, subjectID: String, reason: CallReportReason, details: String) async throws
    func block(volunteerID: String, callID: String) async throws
}

protocol VolunteerSettingsStore: Sendable {
    func preferences() async throws -> VolunteerPreferences
    func save(_ preferences: VolunteerPreferences) async throws
    func isInvited() async throws -> Bool
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

// MARK: - Route preferences (PREF-2)

/// The signed-in user's route preferences on the server. A missing document loads as nil; a failed read throws.
protocol RoutePreferencesSyncing: Sendable {
    func load(userID: String) async throws -> RoutePreferences?
    func save(_ preferences: RoutePreferences, userID: String) async throws
}
