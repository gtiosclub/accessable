import CoreGraphics
import Foundation
import os

// Stand-in implementations of every protocol in ServiceProtocols.swift.
// They let the app run and SwiftUI previews render before the real services exist.
// Subteams: replace the matching entry in `AppServices.live` when your implementation is ready,
// and keep these around for previews and unit tests.

private let log = Logger(subsystem: "AccessAble", category: "Placeholder")

actor PlaceholderCallSafety: CallSafetyService {
    private var consent = false
    private var blocked: Set<String> = []
    func hasConsent() async throws -> Bool { consent }
    func acceptConsent() async throws { consent = true }
    func report(callID: String, subjectID: String, reason: CallReportReason, details: String) async throws {
        guard CallSafetyReportLimit.length(of: details) <= CallSafetyReportLimit.maxLength else { throw CallSafetyError.invalidReport }
    }
    func block(volunteerID: String, callID: String) async throws { blocked.insert(volunteerID) }
}

actor PlaceholderVolunteerSettings: VolunteerSettingsStore {
    private var value = VolunteerPreferences()
    func preferences() async throws -> VolunteerPreferences { value }
    func save(_ preferences: VolunteerPreferences) async throws { value = preferences }
    func isInvited() async throws -> Bool { true }
}

/// Logs events and republishes them; no priority queue or speech. Replaced by 3.3.
actor PlaceholderAnnouncementEngine: AnnouncementEngineProtocol {
    private nonisolated let delivered = Broadcaster<AnnouncementEvent>()
    private var profile: GuidanceProfile = .default
    private var isPaused = false
    private var isInCall = false
    private var last: AnnouncementEvent?
    private let callSettings: CallerSettings

    init(callSettings: CallerSettings = CallerSettings()) {
        self.callSettings = callSettings
    }

    func submit(_ event: AnnouncementEvent) async {
        // The same in-call rule as the real engine, so previews and tests behave like the app.
        guard !isPaused, profile.allows(event), !event.isExpired(),
              CallAnnouncementPolicy.allows(event, duringCall: isInCall, preferences: callSettings.preferences)
        else { return }
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
    func setInCall(_ inCall: Bool) async { isInCall = inCall }
}

struct PlaceholderHaptics: HapticRendering {
    func play(_ id: HapticID, intensity: Float) async {
        log.info("haptic \(id.rawValue) @ \(intensity)")
    }
    func stop() async {
        log.info("haptic stop")
    }
}

/// Sends the given landmarks, then finishes. Empty by default, which is what the app gets until CV's
/// implementation lands. Replaced by CV (LAND-1).
struct PlaceholderLandmarkProvider: LandmarkObserving {
    var observations: [LandmarkObservation] = []

    func landmarkObservations() -> AsyncStream<LandmarkObservation> {
        AsyncStream { continuation in
            observations.forEach { continuation.yield($0) }
            continuation.finish()
        }
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
        SceneDescriptionBuilder().describe(Self.sample)
    }

    /// Answers from the sample scene with Ask AI's offline template, so asking about the
    /// camera can be tried in the Simulator.
    func ask(_ question: String, locationContext: String?) async throws -> String {
        var facts = ImageFacts()
        facts.detections = Self.sample.prioritizedDetections
        facts.elevationHazards = Self.sample.elevationHazards
        // The sample scene has no sign, so add one: "where is the exit?" can then be tried here.
        facts.text = Self.sample.recognizedText + [
            RecognizedText(id: UUID(), string: "EXIT", confidence: 0.95, boundingBox: CGRect(x: 0.7, y: 0.1, width: 0.1, height: 0.05), worldPosition: nil)
        ]
        return TemplateAskAIResponder().answer(question, facts: facts)
    }
}

/// Emits one sample fix, heading, and granted permission so UI work can proceed without GPS. Replaced by 2.1.
struct PlaceholderLocationProvider: LocationProvider {
    func locationSamples() -> AsyncStream<LocationSample> {
        AsyncStream { continuation in
            continuation.yield(MapsSamples.location)
            continuation.finish()
        }
    }

    func headingSamples() -> AsyncStream<HeadingSample> {
        AsyncStream { continuation in
            continuation.yield(MapsSamples.heading)
            continuation.finish()
        }
    }

    func authorizationStates() -> AsyncStream<LocationAuthorization> {
        AsyncStream { continuation in
            continuation.yield(.authorized(preciseAccuracy: true))
            continuation.finish()
        }
    }

    func requestAuthorization() async {}
}

/// Returns the sample route for any request, so previews and tests never reach Valhalla.
struct PlaceholderRoutingService: RoutingService {
    func route(
        from origin: GeoCoordinate, to destination: GeoCoordinate, options: RouteOptions
    ) async throws -> NavigationRoute {
        MapsSamples.route
    }
}

/// Hardcoded campus places so previews don't call MapKit.
struct PlaceholderDestinationSearch: DestinationSearching {
    static let samples = [
        SearchSuggestion(title: "Georgia Tech Library", subtitle: "260 Fourth St NW, Atlanta, GA"),
        SearchSuggestion(title: "John Lewis Student Center", subtitle: "351 Ferst Dr NW, Atlanta, GA"),
        SearchSuggestion(title: "Campus Recreation Center", subtitle: "750 Ferst Dr NW, Atlanta, GA"),
    ]

    /// Replays the latest results, so a listener that subscribes after a query still gets them.
    private let results = Broadcaster<Result<[SearchSuggestion], DestinationSearchError>>(replaysLatest: true)

    func suggestions() -> AsyncStream<Result<[SearchSuggestion], DestinationSearchError>> {
        results.stream()
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results.send(.success(trimmed.isEmpty ? [] : Self.samples.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }))
    }

    func resolve(_ suggestion: SearchSuggestion) async throws -> Destination {
        Destination(name: suggestion.title, coordinate: MapsSamples.destination.coordinate, address: suggestion.subtitle)
    }
}

struct PlaceholderTripProvider: TripStateProviding, LocationContextProviding {
    func tripStates() -> AsyncStream<TripState> {
        AsyncStream { continuation in
            continuation.yield(.idle)
            continuation.finish()
        }
    }

    func tripRoutes() -> AsyncStream<NavigationRoute?> {
        AsyncStream { $0.finish() }
    }

    func startTrip(route: NavigationRoute, destination: Destination, resumingAtStep: Int?) async {}
    func pauseTrip() async {}
    func resumeTrip() async {}
    func endTrip() async {}
    func reroute() async {}
    func reportQuestionEnded(_ reportID: String, outcome: ReportQuestionOutcome) async {}

    func currentLocationDescription() async -> String? { nil }
}

/// Shows nothing, so previews and tests never put an activity on the lock screen.
struct PlaceholderTripActivityClient: TripActivityClient {
    func start(
        _ attributes: TripActivityAttributes, state: TripActivityAttributes.ContentState, staleDate: Date?
    ) async throws {}
    func update(_ state: TripActivityAttributes.ContentState, staleDate: Date?) async {}
    func end(_ state: TripActivityAttributes.ContentState, immediately: Bool) async {}
    func endAll() async {}
}

/// Publishes one fixed state, so previews can show a trip in progress or arrived.
struct PreviewTripProvider: TripStateProviding {
    let state: TripState

    func tripStates() -> AsyncStream<TripState> {
        AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }

    func tripRoutes() -> AsyncStream<NavigationRoute?> {
        AsyncStream { $0.finish() }
    }

    func startTrip(route: NavigationRoute, destination: Destination, resumingAtStep: Int?) async {}
    func pauseTrip() async {}
    func resumeTrip() async {}
    func endTrip() async {}
    func reroute() async {}
    func reportQuestionEnded(_ reportID: String, outcome: ReportQuestionOutcome) async {}
}

actor PlaceholderAuthService: AuthService {
    static let sampleUser = AuthUser(id: "preview-user")
    private nonisolated let users = Broadcaster<AuthUser?>(replaysLatest: true)
    private var user: AuthUser?
    
    init(signedIn: Bool = true) {
        let user = signedIn ? Self.sampleUser : nil
        self.user = user
        users.send(user)
    }
    
    nonisolated func userChanges() -> AsyncStream<AuthUser?> { users.stream() }
    func currentUser() async -> AuthUser? { user }
    
    func signIn(email: String, password: String) async throws -> AuthUser { setUser(Self.sampleUser)}
    
    func createAccount(email: String, password: String) async throws -> AuthUser {
        setUser(Self.sampleUser)
    }
    
    func signOut() async throws {
        user = nil
        users.send(nil)
    }
    
    private func setUser(_ newUser: AuthUser) -> AuthUser {
        user = newUser
        users.send(newUser)
        return newUser
    }
}

// MARK: - Calls

/// Fixed sample volunteers so the Calls screen works with no backend. Replaced by VOLUNTEER-6.
struct PlaceholderVolunteerDirectory: VolunteerDirectory {
    var volunteers: [Volunteer] = SampleContent.activeVolunteers

    func allVolunteers() -> AsyncStream<[Volunteer]> {
        AsyncStream { continuation in
            continuation.yield(volunteers.sortedForDirectory())
            continuation.finish()
        }
    }
    func onlineVolunteers() -> AsyncStream<[Volunteer]> {
        AsyncStream { continuation in
            continuation.yield(volunteers)
            continuation.finish()
        }
    }
}

/// Remembers the toggle in memory only. Replaced by VOLUNTEER-6.
actor PlaceholderPresenceService: PresenceService {
    private nonisolated let states = Broadcaster<Bool>(replaysLatest: true)

    init() { states.send(false) }

    nonisolated func onlineStates() -> AsyncStream<Bool> { states.stream() }

    func setOnline(_ isOnline: Bool) async throws {
        log.info("presence online=\(isOnline)")
        states.send(isOnline)
    }
}

struct PlaceholderCallSignaling: CallSignaling {
    func requestCall(
        preferring volunteerID: String?,
        progress: @Sendable (CallRequestProgress) -> Void
    ) async throws -> CallTicket {
        progress(.ringing(attempt: 1))
        return sampleTicket(volunteerID: volunteerID ?? "placeholder-volunteer")
    }

    func accept(callID: String) async throws -> CallTicket {
        sampleTicket(volunteerID: "placeholder-volunteer", callID: callID)
    }

    func decline(callID: String) async throws {}
    func skip(callID: String) async throws {}
    func endCall(callID: String) async {}

    private func sampleTicket(volunteerID: String, callID: String = UUID().uuidString) -> CallTicket {
        CallTicket(
            callID: callID, roomName: "placeholder-room", token: "placeholder-token",
            callerID: "placeholder-caller", volunteerID: volunteerID,
            expiresAt: Date().addingTimeInterval(60)
        )
    }
}

/// No unsolicited incoming calls in normal previews. Supply an offer for a ringing preview.
struct PlaceholderIncomingCalls: IncomingCallProviding {
    var call: IncomingCall? = nil

    @MainActor func incomingCalls(volunteerID: String) -> AsyncThrowingStream<IncomingCall?, Error> {
        AsyncThrowingStream { continuation in continuation.yield(call) }
    }
}

/// Walks through the states without touching LiveKit or the camera. Replaced by VOLUNTEER-6.
actor PlaceholderVideoCallSession: VideoCallSession {
    private nonisolated let broadcaster = Broadcaster<CallState>(replaysLatest: true)

    init() { broadcaster.send(.idle) }

    nonisolated func states() -> AsyncStream<CallState> { broadcaster.stream() }

    func connect(with ticket: CallTicket) async throws {
        broadcaster.send(.connecting)
        broadcaster.send(.connected)
    }

    func disconnect() async {
        broadcaster.send(.ended(.hungUp))
    }

    func setMicrophoneMuted(_ muted: Bool) async throws {
        log.info("call muted=\(muted)")
    }

    func flipCamera() async throws {
        log.info("call flip camera")
    }

    func setFlashlight(_ on: Bool) async throws {
        log.info("call flashlight=\(on)")
    }
}

/// In-memory profiles for tests and previews, keyed by the shared auth UID.
actor PlaceholderUserProfileStore: UserProfileStore {
    private var profiles: [String: UserProfile]

    init(profiles: [UserProfile] = []) {
        self.profiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.userID, $0) })
    }

    func load(userID: String) async throws -> UserProfile? { profiles[userID] }

    func save(userID: String, role: UserRole, displayName: String,
              languages: [String]) async throws -> UserProfile {
        guard UserProfileValidation.isValid(displayName: displayName, languages: languages) else {
            throw UserProfileError.invalidProfile
        }
        let profile = UserProfile(userID: userID, role: role, displayName: displayName,
                                  languages: languages, createdAt: profiles[userID]?.createdAt ?? .now)
        profiles[userID] = profile
        return profile
    }
}

/// The in-memory stand-in for reports, used in previews and tests. It refuses the votes the rules refuse, so they
/// behave as they would with Firestore.
actor PlaceholderReportService: ReportService {
    private var storedReports: [Report] = []
    private nonisolated let changes = Broadcaster<[Report]>(replaysLatest: true)
    private let auth: any AuthService
    private let now: @Sendable () -> Date
    private var votes: [String: Set<String>] = [:]
    private var lastVote: [String: Date] = [:]
    /// Who was signed in when each report was submitted, so it is that user's own, as Firestore's private index says.
    private var reporters: [String: String] = [:]

    init(auth: any AuthService = PlaceholderAuthService(), now: @escaping @Sendable () -> Date = { .now }) {
        self.auth = auth
        self.now = now
        changes.send([])
    }

    func submit(_ report: Report) async throws {
        let reporter = await auth.currentUser()?.id
        reporters[report.id] = reporter
        storedReports.removeAll { $0.id == report.id }
        storedReports.append(report)
        changes.send(storedReports)
    }

    func reports(
        near coordinate: GeoCoordinate,
        radius: Double
    ) async throws -> [Report] {
        let time = now()
        return await markingOwn(storedReports.filter { $0.expiresAt > time && $0.isNear(coordinate, within: radius) })
    }

    /// The reports, each marked as the signed-in user's own or not.
    private func markingOwn(_ reports: [Report]) async -> [Report] {
        let userID = await auth.currentUser()?.id
        return reports.map { report in
            var report = report
            report.isOwn = userID != nil && reporters[report.id] == userID
            return report
        }
    }

    nonisolated func reportChanges(
        near coordinate: GeoCoordinate,
        radius: Double
    ) -> AsyncStream<[Report]> {
        let source = changes.stream()

        return AsyncStream { continuation in
            let task = Task {
                for await reports in source {
                    let time = self.now()
                    continuation.yield(await self.markingOwn(reports.filter {
                        $0.expiresAt > time && $0.isNear(coordinate, within: radius)
                    }))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @discardableResult
    func confirm(_ reportID: String, isStillPresent: Bool) async throws -> Bool {
        guard let user = await auth.currentUser() else { throw ReportServiceError.notSignedIn }
        let time = now()
        guard !FirestoreReportService.isRateLimited(lastReportAt: lastVote[user.id], now: time) else {
            throw ReportServiceError.rateLimited
        }
        guard let index = storedReports.firstIndex(where: { $0.id == reportID }) else {
            throw ReportServiceError.invalidReport
        }
        var report = storedReports[index]
        report.isOwn = reporters[reportID] == user.id
        guard FirestoreReportService.canVote(on: report, isStillPresent: isStillPresent, now: time),
              votes[reportID, default: []].insert(user.id).inserted else {
            throw ReportServiceError.permissionDenied
        }
        lastVote[user.id] = time

        var voted = report
        var extends = false
        if isStillPresent {
            voted.confirmations += 1
            voted.negativesSinceConfirm = 0
            let renewed = time.addingTimeInterval(report.kind.lifetime)
            extends = renewed > report.expiresAt
            if extends { voted.expiresAt = renewed }
        } else {
            voted.negativeConfirmations += 1
            voted.negativesSinceConfirm += 1
            if voted.negativesSinceConfirm >= FirestoreReportService.removalDenials { voted.expiresAt = time }
        }
        storedReports[index] = voted
        changes.send(storedReports)
        return extends
    }
}
