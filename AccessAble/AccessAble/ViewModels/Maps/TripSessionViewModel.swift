import Foundation
import Observation
import os

private let log = Logger(subsystem: "AccessAble", category: "TripSession")

/// A report question on screen, while its answer is waited for.
struct OpenReportQuestion: Equatable, Sendable {
    let reportID: String
    let text: String
}

/// Owner: Maps (2.x) + Interaction (3.x). State for the redesigned trip screen.
///
/// With services (the app), it walks a real trip: a Valhalla route from where the user is to
/// the chosen place (through `TripViewModel`), turn-by-turn from `TripManager`, obstacle
/// warnings from the camera pipeline, and the Route Blocked Ahead page when the path stays
/// blocked with no way round. Every bar on screen is something the announcement engine
/// delivered, so what is shown is what was said.
///
/// Without services (tests, previews) it is front end only: announcements are whatever is
/// added, and voice commands show their sample responses.
@MainActor
@Observable
final class TripSessionViewModel {
    let plan: TripPlan
    private(set) var announcements: [TripAnnouncement]
    var isMicMuted = true
    private(set) var isPaused = false
    private(set) var isRouteBlocked = false
    var showsMap = false

    /// How many announcements stay on screen; older ones scroll off.
    static let visibleAnnouncementLimit = 3

    /// Real directions; nil when front end only.
    let directions: TripViewModel?

    /// What the microphone heard so far, shown while listening; nil when not listening.
    private(set) var heard: String?
    /// True from the end of speech until the reply has been said.
    private(set) var isAnswering = false
    /// True while Ask AI re-checks fresh frames for something not in view yet.
    private(set) var isLookingAgain = false
    /// A question about a report just walked past, open for its answer by voice or the on-screen buttons.
    private(set) var reportQuestion: OpenReportQuestion?
    /// Active reports near the route, for the map; none without a real trip or where reporting isn't available.
    private(set) var mapReports: [Report] = []
    let dictation = SpeechDictation()
    /// Starts a call with a volunteer (VOLUNTEER-7); set by the screen, which owns navigation.
    @ObservationIgnored var onCallHelp: (() -> Void)?

    /// Listening stops after this long without new words.
    /// Long enough to pause for thought mid-sentence; tapping the mic sends straight away.
    static let silenceTimeout: Duration = .milliseconds(2500)
    /// While something asked about isn't in view, Ask AI looks again this often, for this long.
    static let lookAgainEvery: Duration = .seconds(2)
    static let keepLookingFor: Duration = .seconds(20)
    /// How far ahead on the route a report from Route Blocked Ahead goes: the blockage it
    /// answers is at most this far ahead.
    static let reportAheadDistance = Double(RouteBlockDetector().blockedWithin)
    /// A report question is listened for this long once said and nothing else is waiting; its buttons show from the
    /// start. One not said within the limit, dropped or queued behind other speech, has only its buttons.
    static let answerWindow: Duration = .seconds(8)
    static let questionSpeechLimit: Duration = .seconds(15)
    /// Seconds; a question older than this is from before the screen was listening, such as an earlier trip's.
    static let questionFreshness: TimeInterval = 2

    @ObservationIgnored private let services: AppServices?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let recentPlaces: RecentPlacesStore?
    @ObservationIgnored private let warningLifetime: Duration
    @ObservationIgnored private let infoLifetime: Duration
    @ObservationIgnored private var blockDetector = RouteBlockDetector()
    @ObservationIgnored private var hasSetDestination = false
    @ObservationIgnored private var hasRecordedRecent = false
    @ObservationIgnored private var conversation = AskAIConversation()
    /// The last obstacle warning and the last thing said on this trip, for "repeat".
    @ObservationIgnored private var lastWarning: String?
    @ObservationIgnored private var lastSaid: String?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var voiceTask: Task<Void, Never>?
    /// Whether geo-tracking was asked for with the camera the screen holds; nil while it holds none.
    @ObservationIgnored private var heldCamera: Bool?
    /// Whether this trip can geo-track, asked once: the view model lives for one trip, so the
    /// screen coming back doesn't wait on Apple again.
    @ObservationIgnored private var canGeoTrack: Bool?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let mayListenForAnswers: @MainActor () -> Bool
    @ObservationIgnored private var questionTask: Task<Void, Never>?
    /// The question the listening is for, when the question started it rather than the user.
    @ObservationIgnored private var listeningQuestion: OpenReportQuestion?
    @ObservationIgnored private var answeredReportIDs: Set<String> = []
    /// Questions already told "Didn't catch that.", which is said once each.
    @ObservationIgnored private var missedAnswerIDs: Set<String> = []
    /// The camera picture waits for this. Its view takes its own hold on the camera, and a hold taken before the
    /// geo-tracking ask starts the session on world tracking, which a running session keeps for the whole trip.
    private(set) var isCameraReady = false

    /// - Parameters:
    ///   - services: The app's services, for a real trip; nil for front end only.
    ///   - recentPlaces: Where destinations are recorded when the trip starts.
    ///   - warningLifetime, infoLifetime: How long a red or blue bar stays before it fades.
    ///   - now: The time, for how old a location fix is and when a report is made.
    ///   - clock: Times a report question's answer window.
    ///   - mayListenForAnswers: Whether a report question may switch on the microphone: only once speech and the
    ///     microphone are allowed, so a question never brings up a permission prompt mid-walk.
    init(
        plan: TripPlan,
        services: AppServices? = nil,
        recentPlaces: RecentPlacesStore? = nil,
        announcements: [TripAnnouncement] = [],
        warningLifetime: Duration = .seconds(8),
        infoLifetime: Duration = .seconds(12),
        now: @escaping () -> Date = { .now },
        clock: any Clock<Duration> = ContinuousClock(),
        mayListenForAnswers: @escaping @MainActor () -> Bool = { SpeechDictation.isAllowed }
    ) {
        self.plan = plan
        self.services = services
        self.recentPlaces = recentPlaces
        self.now = now
        self.clock = clock
        self.mayListenForAnswers = mayListenForAnswers
        self.directions = services.map { TripViewModel(services: $0, now: now) }
        self.warningLifetime = warningLifetime
        self.infoLifetime = infoLifetime
        self.announcements = []
        for announcement in announcements.suffix(Self.visibleAnnouncementLimit) { add(announcement) }
    }

    var latestAnnouncement: TripAnnouncement? { announcements.last }

    /// True when the announcement engine speaks what is shown (a real trip), so the screen
    /// mustn't post the same words to VoiceOver again: the engine already speaks through
    /// VoiceOver when it is running.
    var isSpokenByEngine: Bool { services != nil }

    var destinationName: String { plan.place.name }

    /// Whether the trip offers reporting a problem: only once a real report service is wired.
    var isReportingAvailable: Bool { services?.reportsAvailable == true }

    var hasArrived: Bool { directions?.tripState.phase == .arrived }

    /// VoiceOver reads the map as this one element, the reports on it included.
    var mapAccessibilityLabel: String {
        let map = directions?.mapAccessibilityLabel ?? "Map showing walking directions to \(destinationName)."
        let route = directions?.route
        let fix = directions?.currentFix
        guard let reports = MapReportsDescription.text(
            mapReports,
            route: route,
            walked: route.flatMap { route in
                directions?.tripState.distanceRemaining.map { route.totalDistance - $0 }
            },
            location: fix?.coordinate,
            // only a course the user is walking on, and only while it is fresh: standing, or from a fix seconds old,
            // the way they face may be any way
            heading: fix.flatMap { fix in
                now().timeIntervalSince(fix.timestamp) <= HeadingEstimator.maximumSampleAge
                    ? HeadingEstimator.walkingDirection(of: fix) : nil
            },
            distances: services?.distanceSettings.formatter ?? .metric
        ) else { return map }
        return "\(map) \(reports)"
    }

    /// One line on where directions stand, or nil while walking normally.
    var directionsStatus: String? {
        guard let directions else { return nil }
        if directions.needsLocationAccess { return "Directions need Precise Location. Turn it on in Settings." }
        if let error = directions.routeErrorMessage { return error }
        switch directions.tripState.phase {
        case .planning: return "Finding a walking route to \(destinationName)…"
        case .arrived: return "You have arrived at \(destinationName)."
        case .active, .paused: return nil
        }
    }

    func add(_ announcement: TripAnnouncement) {
        announcements.append(announcement)
        if announcements.count > Self.visibleAnnouncementLimit {
            announcements.removeFirst(announcements.count - Self.visibleAnnouncementLimit)
        }
        // Bars fade away rather than pile up: a warning is stale sooner than a direction.
        let lifetime = announcement.kind == .warning ? warningLifetime : infoLifetime
        Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            self?.announcements.removeAll { $0.id == announcement.id }
        }
    }

    // MARK: - Running a real trip

    /// Runs the trip while the screen is open: holds the camera (so warnings keep coming in
    /// map view), finds the route and starts it, and shows what is announced. Returns when
    /// the calling task is cancelled. The trip itself carries on in `TripManager` until
    /// `exit()`, so opening Settings from the paused card doesn't end it.
    func run() async {
        if !hasRecordedRecent {
            hasRecordedRecent = true
            recentPlaces?.record(plan: plan)
        }
        guard let services, let directions else { return }
        if !hasSetDestination {
            hasSetDestination = true
            if let planned = plan.plannedRoute {
                // The route picked on the previous screen; no second request.
                directions.use(planned)
            } else {
                directions.setDestination(Destination(
                    name: plan.place.name,
                    coordinate: GeoCoordinate(latitude: plan.place.latitude, longitude: plan.place.longitude),
                    // A place from search may have no address.
                    address: plan.place.address.isEmpty ? nil : plan.place.address
                ))
            }
            if let origin = plan.origin {
                await say("Directions start from where you are now, not from \(origin.name).", category: .system)
            }
        }
        let camera = services.tripCamera
        await withDiscardingTaskGroup { group in
            group.addTask { await self.openCamera(camera) }
            group.addTask { await directions.start() }
            group.addTask { await self.startWhenRouteIsReady() }
            group.addTask { await self.showAnnouncements(from: services.announcements) }
            group.addTask { await self.watchForBlockedPath(services.scene) }
            group.addTask {
                for await question in services.trip.reportQuestions() {
                    await self.askAbout(question)
                }
            }
            group.addTask {
                for await reports in services.trip.mapReports() {
                    await self.showOnMap(reports)
                }
            }
        }
        stopListening()
        await closeCamera(camera)
    }

    /// Shows the reports TripManager sends for the map.
    func showOnMap(_ reports: [Report]) {
        mapReports = reports
    }

    /// Opens the camera beside the route request rather than before it, since asking Apple about
    /// geo-tracking can take a few seconds. The screen usually opens it before the trip goes active,
    /// so it decides the tracking.
    func openCamera(_ camera: TripCamera) async {
        let geoTracking: Bool
        if let canGeoTrack {
            geoTracking = canGeoTrack
        } else {
            geoTracking = await camera.canGeoTrack()
            // a cancelled check says no without Apple's answer, so it isn't kept
            guard !Task.isCancelled else { return }
            canGeoTrack = geoTracking
        }
        // the screen closed while Apple was asked
        guard !Task.isCancelled else { return }
        do {
            try await camera.start(geoTracking: geoTracking)
            heldCamera = geoTracking
        } catch {
            log.error("No obstacle detection on the trip screen: \(error.localizedDescription, privacy: .public)")
        }
        // also after a failed start, so the camera view can say what went wrong
        isCameraReady = true
    }

    /// Gives back the camera the screen holds, if any.
    func closeCamera(_ camera: TripCamera) async {
        isCameraReady = false
        guard let geoTracking = heldCamera else { return }
        // cleared first, so a run() that starts meanwhile keeps its own hold
        heldCamera = nil
        await camera.stop(geoTracking: geoTracking)
    }

    /// Starts walking as soon as a route is ready, and again after a re-route. Each route is tried
    /// once: a start that doesn't take (the refresh failed, or the trip stayed in planning) would
    /// otherwise make `canStartTrip` true again at once and retry forever on the main actor.
    private func startWhenRouteIsReady() async {
        guard let directions else { return }
        var tried: NavigationRoute?
        for await ready in Observations({ directions.canStartTrip ? directions.route : nil }) {
            guard let ready, ready != tried else { continue }
            await directions.startTrip()
            // the route the start ended with: a refresh inside it may have replaced this one
            tried = directions.route
        }
    }

    private func showAnnouncements(from engine: any AnnouncementEngineProtocol) async {
        for await event in engine.deliveredEvents() {
            guard !event.text.isEmpty else { continue }
            if event.category == .hazard { lastWarning = event.text }
            lastSaid = event.text
            add(TripAnnouncement(text: event.text, kind: event.category == .hazard ? .warning : .info))
        }
    }

    private func watchForBlockedPath(_ scene: any SceneObservationProviding) async {
        // The path assessment comes from the camera pipeline's occupancy map; the sample
        // scene (Simulator, previews) has none.
        guard let analyzer = scene as? ARSceneAnalyzer else { return }
        for await observation in analyzer.observations() {
            let time = observation.timestamp.timeIntervalSinceReferenceDate
            guard !isPaused, !isRouteBlocked else {
                blockDetector.dismiss(at: time)
                continue
            }
            if blockDetector.update(analyzer.perception.diagnostics.path, at: time) {
                isRouteBlocked = true
                await say("Route blocked ahead. Something is in the way with no way round.", category: .hazard)
            }
        }
    }

    // MARK: - Report questions

    /// Asks the question aloud and opens it: the screen shows Yes and No, and once it has been said the microphone
    /// listens for the answer, unless speech or the microphone isn't allowed. No answer in time is no vote. The trip
    /// hears when it ends, or that it wasn't asked. Internal so tests can ask without a trip.
    func askAbout(_ question: ReportQuestion) async {
        guard let services else { return }
        let report = question.report
        if answeredReportIDs.contains(report.id) {
            await services.trip.reportQuestionEnded(report.id, outcome: .unanswered)
            return
        }
        guard isReportingAvailable, reportQuestion == nil,
              directions?.tripState.phase == .active,
              now().timeIntervalSince(question.askedAt) <= Self.questionFreshness,
              !report.isOwn, await services.auth.currentUser() != nil,
              // checked again after the await
              reportQuestion == nil else {
            await services.trip.reportQuestionEnded(report.id, outcome: .notAsked)
            return
        }
        let open = OpenReportQuestion(reportID: report.id, text: report.kind.stillThereQuestion)
        reportQuestion = open
        let event = AnnouncementEvent(category: .system, priority: .high, text: open.text, source: .userInteraction)
        // before the submit, so its end can't be missed
        let finished = services.announcements.finishedEvents()
        questionTask = Task { [weak self, clock] in
            let quiet = await Self.waitForQuiet(after: event.id, finished: finished, clock: clock)
            guard !Task.isCancelled else { return }
            // the buttons still show; listening while something else is said would fight it for the audio
            if quiet, self?.mayListenForAnswers() == true { await self?.listenForAnswer(to: open) }
            do { try await clock.sleep(for: Self.answerWindow) } catch { return }
            self?.end(open, outcome: .unanswered)
        }
        await services.announcements.submit(event)
    }

    /// Waits for the question to be said and nothing else to be waiting, since listening switches the audio session
    /// over and would cut speech off. Returns whether it may listen: false when the question was cut off, as for a
    /// warning, or when `questionSpeechLimit` passed first, with the question dropped or still waiting.
    private static func waitForQuiet(
        after id: UUID, finished: AsyncStream<FinishedAnnouncement>, clock: any Clock<Duration>
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var said = false
                for await end in finished {
                    if end.id == id {
                        guard !end.wasInterrupted else { return false }
                        said = true
                    }
                    if said, end.isIdle { return true }
                }
                // an engine that doesn't speak
                return true
            }
            group.addTask {
                try? await clock.sleep(for: questionSpeechLimit)
                return false
            }
            let quiet = await group.next() ?? false
            group.cancelAll()
            return quiet
        }
    }

    /// Listens for the answer unless the user is already speaking. What it hears is only ever an answer.
    private func listenForAnswer(to question: OpenReportQuestion) async {
        guard reportQuestion == question, !dictation.isRecording else { return }
        listeningQuestion = question
        await startListening(armingSilence: false)
        if !dictation.isRecording { listeningQuestion = nil }
    }

    /// Ends the question and, given an `outcome`, tells the trip, which waits for this before the next.
    private func end(_ question: OpenReportQuestion, outcome: ReportQuestionOutcome?) {
        guard reportQuestion == question else { return }
        reportQuestion = nil
        questionTask?.cancel()
        questionTask = nil
        stopListening(for: question)
        if let outcome { tellTrip(question, outcome) }
    }

    private func tellTrip(_ question: OpenReportQuestion, _ outcome: ReportQuestionOutcome) {
        guard let trip = services?.trip else { return }
        Task { await trip.reportQuestionEnded(question.reportID, outcome: outcome) }
    }

    /// Stops the listening the question started. Words already coming are let finish, so an answer begun just before
    /// the end still counts; with none, it is cancelled without a word.
    private func stopListening(for question: OpenReportQuestion) {
        guard listeningQuestion == question else { return }
        if dictation.isRecording, heard?.isEmpty == false {
            dictation.stop()
            return
        }
        listeningQuestion = nil
        silenceTask?.cancel()
        dictation.cancel()
        heard = nil
    }

    /// Votes on the question's report, by the buttons or a spoken answer. The question is passed in rather than read
    /// back, so the vote is for the report that was asked about even if the question closes meanwhile.
    func answer(_ question: OpenReportQuestion, isStillPresent: Bool) async {
        guard let services, answeredReportIDs.insert(question.reportID).inserted else { return }
        // the trip hears once the vote is sent or has failed, since only a sent one holds the next question back
        end(question, outcome: nil)
        do {
            let extended = try await services.reports.confirm(question.reportID, isStillPresent: isStillPresent)
            tellTrip(question, .voted)
            await say(
                !isStillPresent ? "Thanks." : extended ? "Thanks, the report is extended." : "Thanks, the report is confirmed.",
                category: .system
            )
        } catch ReportServiceError.rateLimited {
            tellTrip(question, .unanswered)
            await say("Wait a minute before answering again.", category: .system)
        } catch {
            tellTrip(question, .unanswered)
            log.error("Report vote failed: \(String(describing: error), privacy: .public)")
            await say("Couldn't send your answer.", category: .system)
        }
    }

    /// What the question's own listening heard: an answer votes, and anything else is dropped, never taken as a
    /// command or a question, with "Didn't catch that." said once a question. Internal so tests can answer without
    /// the microphone.
    func heardAnswer(_ text: String, to question: OpenReportQuestion) async {
        if let isStillPresent = Self.reportAnswer(for: text) {
            await answer(question, isStillPresent: isStillPresent)
            return
        }
        log.notice("Heard something other than an answer to a report question")
        // not once the question has gone from the screen
        guard reportQuestion == question, missedAnswerIDs.insert(question.reportID).inserted else { return }
        await say("Didn't catch that.", category: .system)
    }

    /// true for yes, false for no, or nil when the words aren't an answer. Speech adds punctuation, so it is ignored.
    /// - Parameter anywhere: Whether an answer may be part of a longer sentence, as it may in the question's own
    ///   listening; otherwise only the whole of what was said counts, so a command or question isn't taken for one.
    static func reportAnswer(for text: String, anywhere: Bool = true) -> Bool? {
        // a question back, such as the question said over, isn't an answer
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") else { return nil }
        let said = " " + text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
        guard anywhere else {
            let whole = said.trimmingCharacters(in: .whitespaces)
            if ["yes", "yeah", "yep", "yup", "still there", "still blocked", "it's still there", "it's still blocked"]
                .contains(whole) {
                return true
            }
            if ["no", "nope", "nah", "clear", "it's clear", "gone", "it's gone"].contains(whole) { return false }
            return nil
        }
        return answerInSentence(said)
    }

    private static let yesWords: Set = ["yes", "yeah", "yep", "yup"]
    private static let noWords: Set = ["no", "nope", "nah"]
    /// Words saying the problem is there, and that it has gone; either, negated, says the other.
    private static let presentWords: Set = ["blocked", "there", "closed", "out", "broken", "ongoing"]
    private static let goneWords: Set = ["gone", "clear", "cleared", "open", "fixed", "working", "works", "work"]

    /// Every cue in the sentence must agree: a leading yes or no, a later yes or no, and each word that says the
    /// problem is there or gone, turned round by a "not", "nothing" or "-n't" up to two words before it. Doubt or a
    /// contradiction is no answer, since a wrong vote is worse than none.
    private static func answerInSentence(_ said: String) -> Bool? {
        let doubts = [" no idea ", " no clue ", " not sure ", " don't know ", " dont know ", " do not know ", " maybe "]
        guard !doubts.contains(where: said.contains) else { return nil }
        // work still going on is the problem still there, not something working again
        let isOngoing = said.contains(" working on ") || said.contains(" going on ")
        var words = said.replacingOccurrences(of: " no longer ", with: " not anymore ")
            .replacingOccurrences(of: " out of the way ", with: " gone ")
            .replacingOccurrences(of: " working on ", with: " ongoing ")
            .replacingOccurrences(of: " going on ", with: " ongoing ")
            .split(separator: " ").map(String.init)
        while let first = words.first, ["uh", "um", "er", "oh", "well"].contains(first) { words.removeFirst() }
        var answers: [Bool] = []
        var start = 0
        if let first = words.first, yesWords.contains(first) || noWords.contains(first) {
            answers.append(yesWords.contains(first))
            start = 1
        }
        func isNegator(_ word: String) -> Bool {
            ["not", "never", "no", "cannot", "nothing", "nothing's", "none"].contains(word) || word.hasSuffix("n't")
        }
        for index in words.indices.dropFirst(start) {
            let word = words[index]
            let negated = words[max(start, index - 2)..<index].contains(where: isNegator)
            if yesWords.contains(word) {
                answers.append(true)
            } else if noWords.contains(word) {
                answers.append(false)
            } else if isOngoing, ["work", "works", "working"].contains(word) {
                continue
            } else if word == "anymore", negated {
                answers.append(false)
            } else if presentWords.contains(word) {
                answers.append(!negated)
            } else if goneWords.contains(word) {
                answers.append(negated)
            }
        }
        guard let answer = answers.first, answers.allSatisfy({ $0 == answer }) else { return nil }
        return answer
    }

    // MARK: - Commands

    /// Runs a command from the Voice Commands sheet. Returns false for commands that open
    /// other UI: Call Help, and the report choices.
    @discardableResult
    func run(_ command: VoiceCommandHint) -> Bool {
        switch command {
        case .pauseTrip:
            pause()
            return true
        case .callHelp, .reportProblem:
            return false
        default:
            guard let services else {
                guard let response = command.sampleResponse else { return false }
                add(response)
                return true
            }
            Task { await self.perform(command, with: services) }
            return true
        }
    }

    /// The real command. What it says comes back from the engine as a bar.
    private func perform(_ command: VoiceCommandHint, with services: AppServices) async {
        let text: String
        switch command {
        case .repeatWarning:
            await repeatWarning()
            return
        case .describeSurroundings:
            text = await services.sceneDescriber.describeCurrentScene()
        case .describeLocation:
            text = await services.locationContext.currentLocationDescription()
                ?? "I couldn't find where you are. Check that Location is on for AccessAble, or try again outside."
        case .pauseTrip, .reportProblem, .callHelp:
            return
        }
        await say(text, category: .ambient)
    }

    private func say(_ text: String, category: AnnouncementCategory) async {
        guard let services else {
            add(TripAnnouncement(text: text, kind: category == .hazard ? .warning : .info))
            return
        }
        await services.announcements.submit(AnnouncementEvent(
            category: category, priority: .high, text: text, source: .userInteraction
        ))
    }

    // MARK: - Microphone

    var isListening: Bool { dictation.isRecording }

    /// Whether the mic button shows as off: on a real trip, off unless listening.
    var isMicOff: Bool { services == nil ? isMicMuted : !isListening }

    /// Starts listening; tapping again while listening sends what was heard. Listening also
    /// stops by itself after a pause. Front end only, it just flips the button.
    func toggleMicrophone() async {
        guard services != nil else {
            isMicMuted.toggle()
            return
        }
        if dictation.isRecording {
            // listening for a question's answer becomes the user's own, so what they say goes where it would
            guard listeningQuestion == nil else {
                listeningQuestion = nil
                armSilenceTimer()
                return
            }
            dictation.stop()
            return
        }
        // the question's late words are done with: what the user starts now is their own
        listeningQuestion = nil
        await startListening(armingSilence: true)
    }

    /// - Parameter armingSilence: Whether listening stops after a pause from the start, or only once words come.
    private func startListening(armingSilence: Bool) async {
        voiceTask?.cancel()
        heard = ""
        dictation.onTranscript = { [weak self] text, isFinal in self?.didHear(text, isFinal: isFinal) }
        dictation.onError = { [weak self] message in
            guard let self else { return }
            heard = nil
            guard listeningQuestion == nil else {
                listeningQuestion = nil
                log.notice("No answer heard to a report question: \(message, privacy: .public)")
                return
            }
            Task { await self.say(message, category: .system) }
        }
        await dictation.start()
        if !dictation.isRecording {
            heard = nil
        } else if armingSilence {
            armSilenceTimer()
        }
    }

    private func didHear(_ text: String, isFinal: Bool) {
        heard = text
        guard isFinal else {
            armSilenceTimer()
            return
        }
        silenceTask?.cancel()
        heard = nil
        if let question = listeningQuestion {
            listeningQuestion = nil
            voiceTask = Task { await self.heardAnswer(text, to: question) }
        } else {
            voiceTask = Task { await self.respond(to: text) }
        }
    }

    /// A spoken "report …": the kind of problem, or a report whose kind wasn't heard.
    enum ReportCommand: Equatable {
        case kind(ReportKind)
        case unknown
    }

    /// What may come before "report". Only these, not "report" anywhere, so a question such as
    /// "what does this report say" still goes to Ask AI.
    private static let reportLeadIns = ["", "please ", "ok ", "okay ", "i want to ", "i'd like to ", "i would like to ", "i need to ", "can i "]

    /// nil unless the words are a report command. Speech adds punctuation, so it is ignored.
    static func reportCommand(for text: String) -> ReportCommand? {
        let words = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let leadIn = reportLeadIns.first(where: { words == "\($0)report" || words.hasPrefix("\($0)report ") }) else {
            return nil
        }
        // padded, so each phrase matches whole words only
        let problem = " \(words.dropFirst(leadIn.count + "report".count)) "
        func says(_ phrases: String...) -> Bool { phrases.contains { problem.contains(" \($0) ") } }

        if says("construction", "work zone", "road work", "roadwork") { return .kind(.construction) }
        // before the entrance: "the elevator door is closed" is an elevator out of service
        if says("elevator", "lift") { return .kind(.elevatorOut) }
        // before blocked: "the door is closed" is a closed entrance, not a blocked path
        if says("entrance", "door", "doorway"), says("closed", "locked") { return .kind(.closedEntrance) }
        if says("blocked", "blocking", "obstruction", "obstacle") { return .kind(.blockedPath) }
        if says("other", "something else") { return .kind(.other) }
        return .unknown
    }

    private static let reportingUnavailable = "Reporting isn't available yet."

    /// Submits a report at the user's location or a short distance ahead on the active route.
    func submitReport(kind: ReportKind, useRouteAhead: Bool = false) async {
        guard let services, isReportingAvailable else {
            await say(Self.reportingUnavailable, category: .system)
            return
        }

        guard await services.auth.currentUser() != nil else {
            await say("Sign in to report a problem.", category: .system)
            return
        }

        guard let location = directions?.reportableLocation else {
            await say("Your location isn't precise enough to report yet. Try again in a moment.", category: .system)
            return
        }

        let createdAt = now()
        let report = Report(
            id: UUID().uuidString,
            kind: kind,
            coordinate: useRouteAhead ? pointAhead(of: location) : location,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(kind.lifetime)
        )

        do {
            try await services.reports.submit(report)
            await say("Reported \(kind.title.lowercased()). Thank you.", category: .system)
        } catch ReportServiceError.rateLimited {
            await say("You just sent a report. Wait a minute before sending another.", category: .system)
        } catch ReportServiceError.queuedOffline {
            await say("Saved. It will be sent when you're back online.", category: .system)
        } catch ReportServiceError.notSignedIn {
            await say("Sign in to report a problem.", category: .system)
        } catch let error as ReportServiceError where error == .permissionDenied || error == .invalidReport {
            log.error("Report refused: \(String(describing: error), privacy: .public)")
            await say("That report couldn't be sent.", category: .system)
        } catch {
            log.error("Report submit failed: \(error.localizedDescription, privacy: .public)")
            await say(
                "I couldn't send that report. Check your connection and try again.",
                category: .system
            )
        }
    }

    /// `reportAheadDistance` on from how far along the route the trip is; `location` while the
    /// trip has no progress to go by.
    private func pointAhead(of location: GeoCoordinate) -> GeoCoordinate {
        guard let route = directions?.route, let remaining = directions?.tripState.distanceRemaining else {
            return location
        }
        let walked = max(0, route.totalDistance - remaining)
        return GeoMath.coordinate(
            atDistance: min(walked + Self.reportAheadDistance, route.totalDistance),
            along: route.coordinates,
            cumulativeDistances: route.cumulativeDistances
        )
    }

    private func armSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.silenceTimeout)
            guard !Task.isCancelled else { return }
            self?.dictation.stop()
        }
    }

    private func stopListening() {
        if let question = reportQuestion { end(question, outcome: .unanswered) }
        listeningQuestion = nil
        silenceTask?.cancel()
        voiceTask?.cancel()
        dictation.cancel()
        heard = nil
        isAnswering = false
        isLookingAgain = false
    }

    /// A trip command is carried out; anything else is a question for Ask AI about what the
    /// camera sees, with the conversation so far, so follow-ups make sense. Internal so tests can
    /// say something without the microphone.
    func respond(to text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let services, !text.isEmpty else { return }
        // only while a question is open: otherwise "no" is a question for Ask AI like any other
        if let question = reportQuestion, let isStillPresent = Self.reportAnswer(for: text, anywhere: false) {
            await answer(question, isStillPresent: isStillPresent)
            return
        }
        if let report = Self.reportCommand(for: text) {
            switch report {
            case .kind(let kind):
                await submitReport(kind: kind)
            case .unknown where isReportingAvailable:
                await say(
                    "What's the problem? Say report, then the problem: report construction, report blocked path, report closed entrance, report elevator, or report other.",
                    category: .system
                )
            case .unknown:
                await say(Self.reportingUnavailable, category: .system)
            }
            return
        }
        if Self.asksForHelp(text) {
            onCallHelp?()
            return
        }
        // Handled here, not by the command parser: the on-device model can take "repeat
        // warning" for a question, and the engine's own repeat replays whatever was said last.
        if let wantsWarning = Self.asksToRepeat(text) {
            await (wantsWarning ? repeatWarning() : repeatLastSaid())
            return
        }
        isAnswering = true
        defer { isAnswering = false }
        switch await services.commands.interpret(text) {
        case .describeSurroundings:
            await perform(.describeSurroundings, with: services)
        case .whereAmI:
            await perform(.describeLocation, with: services)
        case .repeatLast:
            await repeatLastSaid()
        case .pauseTrip:
            pause()
            await say("Trip paused.", category: .system)
        case .resumeTrip:
            resume()
            await say("Trip resumed.", category: .system)
        case .endTrip:
            // Ending is one tap away, but not by voice: a misheard word mustn't drop the route.
            pause()
            await say("Trip paused. To end it, choose Exit Trip.", category: .system)
        case .callVolunteer:
            onCallHelp?()
        case .ask(let question):
            await ask(question, with: services)
        case .unknown:
            await ask(text, with: services)
        }
    }

    /// nil unless asking for a repeat; true when it is the warning that's wanted.
    static func asksToRepeat(_ text: String) -> Bool? {
        let text = text.lowercased()
        guard ["repeat", "say that again", "say again", "what did you say"].contains(where: text.contains) else {
            return nil
        }
        return text.contains("warn") || text.contains("obstacle") || text.contains("alert")
    }

    /// Says the last obstacle warning again, or that there hasn't been one.
    private func repeatWarning() async {
        await say(lastWarning ?? "No warnings yet on this trip.", category: lastWarning == nil ? .system : .hazard)
    }

    private func repeatLastSaid() async {
        await say(lastSaid ?? "Nothing to repeat yet.", category: .system)
    }

    /// "Call help", "call for help", "call a volunteer": starts a call. Caught before the
    /// command parser so a slow model never delays it.
    static func asksForHelp(_ text: String) -> Bool {
        let text = text.lowercased()
        return ["call help", "call for help", "call a volunteer", "call volunteer", "call someone", "video call", "get help"]
            .contains { text.contains($0) }
    }

    /// Asks about the camera view. When the answer is that it isn't in view, says to turn
    /// slowly and keeps looking with fresh frames for a while, like Describe mode.
    private func ask(_ question: String, with services: AppServices) async {
        guard let analyzer = services.scene as? ARSceneAnalyzer else {
            // No camera pipeline (Simulator): the plain question service.
            let reply = (try? await services.sceneDescriber.ask(question, locationContext: nil))
                ?? "Sorry, I couldn't look at the camera. Please try again."
            await say(reply, category: .ambient)
            return
        }
        let history = conversation.turns
        var reply: String
        do {
            reply = try await analyzer.ask(question, conversation: history)
        } catch {
            guard !Task.isCancelled else { return }
            await say(error.localizedDescription, category: .system)
            return
        }
        if AskAIConversation.meansNotInView(reply) {
            await say("I can't see that yet. Turn slowly and I'll tell you when I find it.", category: .ambient)
            isLookingAgain = true
            defer { isLookingAgain = false }
            let deadline = ContinuousClock.now + Self.keepLookingFor
            var found: String?
            while found == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: Self.lookAgainEvery)
                guard !Task.isCancelled else { return }
                if let again = try? await analyzer.ask(question, conversation: history),
                   !AskAIConversation.meansNotInView(again) {
                    found = again
                }
            }
            reply = found ?? "I couldn't find it. Try moving closer, or ask again."
        }
        guard !Task.isCancelled else { return }
        conversation.record(question: question, answer: reply)
        await say(reply, category: .ambient)
    }

    // MARK: - Pause, blocked route, exit

    func pause() {
        answerBlockedRoute()
        isPaused = true
        Task { await directions?.togglePauseIfActive() }
    }

    func resume() {
        answerBlockedRoute()
        isPaused = false
        Task { await directions?.resumeIfPaused() }
    }

    func simulateBlockedRoute() {
        isPaused = false
        isRouteBlocked = true
    }

    /// Asks `TripManager` for a new route from where the user is now ("find another way" on
    /// Route Blocked Ahead). It says what happens, so the bars show only real cues. The route
    /// service doesn't know about the obstacle, so the new route is the best one from here,
    /// not one that avoids it.
    func reroute() {
        answerBlockedRoute()
        guard let services else { return }
        Task { await services.trip.reroute() }
    }

    /// Ends the trip for good (Exit Trip).
    func exit() {
        Task { await directions?.endTrip() }
    }

    private func answerBlockedRoute() {
        if isRouteBlocked { blockDetector.dismiss(at: Date.now.timeIntervalSinceReferenceDate) }
        isRouteBlocked = false
    }
}

private extension TripViewModel {
    func togglePauseIfActive() async {
        if tripState.phase == .active { await togglePause() }
    }

    func resumeIfPaused() async {
        if tripState.phase == .paused { await togglePause() }
    }
}
