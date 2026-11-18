import Foundation
import Observation
import os

private let log = Logger(subsystem: "AccessAble", category: "VoiceAgent")

/// Owner: User Interaction (3.1). The hands-free voice agent: listens all the time (unless
/// muted), sends what the user says to Claude with the current screen's controls, carries out
/// the tool calls Claude makes (pressing buttons, typing, navigating, the old voice commands),
/// and speaks the reply.
///
/// Actions on controls marked as needing confirmation never run straight away. The app asks
/// "Should I …? Say yes or no." and only a yes runs them. This check is in code, so the model
/// can't skip it.
@MainActor
@Observable
final class VoiceAgentViewModel {
    enum Status: Equatable {
        /// No Claude API key yet: nothing is listening.
        case needsKey
        case muted
        case starting
        case listening
        /// The words so far.
        case hearing(String)
        case thinking
        /// Waiting for yes or no to this question.
        case confirming(String)
        /// Another screen's push-to-talk microphone is in use.
        case pausedForDictation
        case unavailable(String)
    }

    private(set) var status: Status = .starting
    private(set) var isMuted: Bool
    /// What the agent last said, shown in the bar.
    private(set) var lastReply: String?

    @ObservationIgnored let registry: AgentControlRegistry
    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let router: AppRouter
    @ObservationIgnored private let listener = ContinuousSpeechListener()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var conversation: [JSONValue] = []
    @ObservationIgnored private var lastTurnAt = Date.distantPast
    /// Tool results not sent yet because a confirmation interrupted the turn. The pending
    /// action's slot is nil until the user answers.
    @ObservationIgnored private var heldResults: [JSONValue?] = []
    @ObservationIgnored private var pending: PendingConfirmation?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var workID = 0
    @ObservationIgnored private var isAppActive = true
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var keyObserver: NSObjectProtocol?

    private struct PendingConfirmation {
        let toolUseID: String
        let question: String
        /// Run again with `confirmed` on a yes, so the control is looked up afresh.
        let action: AgentAction
    }

    private enum Outcome {
        case done(String)
        case failed(String)
        case needsConfirmation(question: String)
    }

    private static let mutedKey = "voiceAgentMuted"
    /// A quiet gap this long starts a fresh conversation, so old context doesn't pile up.
    private static let conversationLifetime: TimeInterval = 5 * 60
    private static let maxConversationMessages = 40
    private static let maxToolRounds = 8
    /// Time for a pushed screen to appear and register its controls before the agent looks again.
    private static let settleDelay: Duration = .milliseconds(700)

    init(services: AppServices, router: AppRouter, registry: AgentControlRegistry, defaults: UserDefaults = .standard) {
        self.services = services
        self.router = router
        self.registry = registry
        self.defaults = defaults
        self.isMuted = defaults.bool(forKey: Self.mutedKey)
    }

    isolated deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        listener.onPartial = { [weak self] text in self?.heard(text) }
        listener.onUtterance = { [weak self] text in self?.received(text) }
        listener.onStopped = { [weak self] error in self?.status = .unavailable(error.spokenMessage) }
        AudioSessionCoordinator.shared.onDictationChange = { [weak self] isDictating in
            self?.dictationChanged(isDictating)
        }
        keyObserver = NotificationCenter.default.addObserver(
            forName: ClaudeAPIKeyStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = Task { await self?.refreshListening() }
            }
        }
        await refreshListening()
    }

    func toggleMute() async {
        isMuted.toggle()
        defaults.set(isMuted, forKey: Self.mutedKey)
        if isMuted {
            work?.cancel()
            work = nil
            workID += 1
            resetConversation()
        }
        await refreshListening()
    }

    /// The app moved to or from the background. The microphone is only open in the foreground.
    func appActivityChanged(isActive: Bool) async {
        isAppActive = isActive
        await refreshListening()
    }

    /// Starts or stops the microphone to match the key, mute, dictation and app state.
    func refreshListening() async {
        guard ClaudeAPIKeyStore.current != nil, !isMuted, !AudioSessionCoordinator.shared.isDictating, isAppActive else {
            listener.stop()
            settleStatus()
            return
        }
        guard !listener.isRunning else {
            settleStatus()
            return
        }
        status = .starting
        do {
            try await listener.start()
        } catch let error as ContinuousSpeechListener.StartError {
            status = .unavailable(error.spokenMessage)
            return
        } catch {
            status = .unavailable("The voice assistant couldn't start.")
            return
        }
        // Muted, backgrounded or interrupted while asking for permission.
        if isMuted || !isAppActive || AudioSessionCoordinator.shared.isDictating {
            listener.stop()
        }
        settleStatus()
    }

    // MARK: - Hearing

    private func heard(_ partial: String) {
        guard work == nil else { return }
        status = .hearing(partial)
    }

    private func received(_ utterance: String) {
        log.debug("Heard: \(utterance, privacy: .private)")
        if work != nil {
            // Only "stop" / "cancel" gets through while a request is running.
            if ConfirmationReply(utterance) == .no {
                work?.cancel()
                work = nil
                workID += 1
                resetConversation()
                Task { await say("Okay, stopped.") }
                settleStatus()
            }
            return
        }
        workID += 1
        let id = workID
        work = Task { [weak self] in
            await self?.handle(utterance)
            // A cancelled request must not clear the state of the one after it.
            guard let self, workID == id else { return }
            work = nil
            settleStatus()
        }
    }

    private func dictationChanged(_ isDictating: Bool) {
        if isDictating {
            // Synchronously, before dictation sets up the audio session.
            listener.stop()
            status = .pausedForDictation
        } else {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                await self?.refreshListening()
            }
        }
    }

    private func settleStatus() {
        if ClaudeAPIKeyStore.current == nil {
            status = .needsKey
        } else if isMuted {
            status = .muted
        } else if AudioSessionCoordinator.shared.isDictating {
            status = .pausedForDictation
        } else if let pending {
            status = .confirming(pending.question)
        } else if work != nil {
            status = .thinking
        } else if listener.isRunning {
            status = .listening
        } else if case .unavailable = status {
            // Keep the reason on screen.
        } else {
            status = .muted
        }
    }

    // MARK: - A turn

    private func handle(_ utterance: String) async {
        if Date.now.timeIntervalSince(lastTurnAt) > Self.conversationLifetime {
            resetConversation()
        }

        if let pending {
            self.pending = nil
            switch ConfirmationReply(utterance) {
            case .yes:
                status = .thinking
                let result = switch await execute(pending.action, confirmed: true) {
                case .done(let text): "The user said yes. \(text)"
                case .failed(let text): "The user said yes, but it failed: \(text)"
                case .needsConfirmation: "The user said yes, but it couldn't be done."
                }
                fillPendingResult(pending, with: result)
                conversation.append(["role": "user", "content": .array(takeHeldResults())])
                await runConversation()
                return
            case .no:
                fillPendingResult(pending, with: "The user said no, so nothing was done.")
                lastTurnAt = .now
                await say("Okay, I won't.")
                return
            case .other:
                // A new request instead of an answer: drop the action and handle the request.
                fillPendingResult(pending, with: "The user didn't confirm, so nothing was done.")
            }
        }

        status = .thinking
        var content = takeHeldResults()
        content.append([
            "type": "text",
            "text": .string("\(screenDescription())\n\nThe user said: \"\(utterance)\""),
        ])
        conversation.append(["role": "user", "content": .array(content)])
        await runConversation()
    }

    /// Calls Claude, runs its tool calls, and repeats until it answers in words.
    private func runConversation() async {
        guard let apiKey = ClaudeAPIKeyStore.current else {
            resetConversation()
            return
        }
        let client = ClaudeMessagesClient(apiKey: apiKey)

        for _ in 0 ..< Self.maxToolRounds {
            let response: ClaudeMessagesClient.Response
            do {
                response = try await client.send(messages: conversation)
            } catch is CancellationError {
                resetConversation()
                return
            } catch let failure as ClaudeMessagesClient.Failure {
                resetConversation()
                await say(failure.spokenMessage)
                return
            } catch {
                resetConversation()
                await say(ClaudeMessagesClient.Failure.malformedResponse.spokenMessage)
                return
            }
            guard !Task.isCancelled else {
                resetConversation()
                return
            }
            lastTurnAt = .now
            conversation.append(["role": "assistant", "content": .array(response.content)])

            switch response.stopReason {
            case "tool_use" where !response.toolUses.isEmpty:
                let results = await runTools(response.toolUses)
                guard !Task.isCancelled else {
                    resetConversation()
                    return
                }
                if let pending {
                    heldResults = results
                    await say("\(pending.question) Say yes or no.")
                    return
                }
                conversation.append(["role": "user", "content": .array(results.compactMap { $0 })])
            case "refusal":
                resetConversation()
                await say("Sorry, I can't help with that.")
                return
            default:
                let reply = response.text
                if !reply.isEmpty { await say(reply) }
                if conversation.count > Self.maxConversationMessages { resetConversation() }
                return
            }
        }
        resetConversation()
        await say("Sorry, that took too many steps. Try asking for one thing at a time.")
    }

    private func runTools(_ calls: [ClaudeMessagesClient.ToolUse]) async -> [JSONValue?] {
        var results: [JSONValue?] = []
        for call in calls {
            if pending != nil {
                results.append(toolResult(call.id, "Not done: an earlier action is waiting for the user's confirmation.", isError: true))
                continue
            }
            switch AgentAction.parse(name: call.name, input: call.input) {
            case .failure(let error):
                results.append(toolResult(call.id, error.message, isError: true))
            case .success(let action):
                switch await execute(action, confirmed: false) {
                case .done(let text):
                    results.append(toolResult(call.id, text))
                case .failed(let text):
                    results.append(toolResult(call.id, text, isError: true))
                case .needsConfirmation(let question):
                    pending = PendingConfirmation(toolUseID: call.id, question: question, action: action)
                    results.append(nil)
                }
            }
        }
        return results
    }

    // MARK: - Tools

    /// - Parameter confirmed: The user already said yes, so don't ask.
    private func execute(_ action: AgentAction, confirmed: Bool) async -> Outcome {
        switch action {
        case .press(let id):
            guard let control = registry.control(id: id), let press = registry.handlers(id: id)?.press else {
                return .failed(missing(id, kind: "button"))
            }
            guard control.isEnabled else { return .failed("\(control.label) is disabled right now.") }
            if control.needsConfirmation, !confirmed { return .needsConfirmation(question: "Should I press \(control.label)?") }
            press()
            return .done(await screenAfterAction())

        case .typeText(let id, let text, let submit):
            guard let control = registry.control(id: id), let handlers = registry.handlers(id: id),
                  let setText = handlers.setText
            else { return .failed(missing(id, kind: "text field")) }
            guard control.isEnabled else { return .failed("\(control.label) is disabled right now.") }
            if control.needsConfirmation, !confirmed {
                return .needsConfirmation(question: "Should I type \(text) into \(control.label)?")
            }
            setText(text)
            if submit { handlers.submit?() }
            return .done(await screenAfterAction())

        case .setToggle(let id, let isOn):
            guard let control = registry.control(id: id), let setOn = registry.handlers(id: id)?.setOn else {
                return .failed(missing(id, kind: "toggle"))
            }
            guard control.isEnabled else { return .failed("\(control.label) is disabled right now.") }
            let state = isOn ? "on" : "off"
            if control.value == state { return .done("\(control.label) is already \(state).") }
            if control.needsConfirmation, !confirmed {
                return .needsConfirmation(question: "Should I turn \(state) \(control.label)?")
            }
            setOn(isOn)
            return .done(await screenAfterAction())

        case .setValue(let id, let value):
            guard let control = registry.control(id: id), let handlers = registry.handlers(id: id) else {
                return .failed(missing(id, kind: "slider or choice"))
            }
            guard control.isEnabled else { return .failed("\(control.label) is disabled right now.") }
            if let choose = handlers.choose {
                let wanted = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let option = control.options.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                    let options = control.options.map { "\"\($0)\"" }.joined(separator: ", ")
                    return .failed("\"\(value)\" isn't an option. The options are \(options).")
                }
                if control.needsConfirmation, !confirmed {
                    return .needsConfirmation(question: "Should I set \(control.label) to \(option)?")
                }
                choose(option)
                return .done(await screenAfterAction())
            }
            if let setNumber = handlers.setNumber, let range = control.range {
                guard let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    return .failed("\(control.label) needs a number between \(range.lowerBound.formatted()) and \(range.upperBound.formatted()).")
                }
                let clamped = min(max(number, range.lowerBound), range.upperBound)
                if control.needsConfirmation, !confirmed {
                    let amount = clamped.formatted(.number.precision(.fractionLength(0 ... 2)))
                    return .needsConfirmation(question: "Should I set \(control.label) to \(amount)?")
                }
                setNumber(clamped)
                return .done(await screenAfterAction())
            }
            return .failed("\(control.label) isn't a slider or a choice.")

        case .navigate(let destination):
            if let problem = navigate(to: destination) { return .failed(problem) }
            return .done(await screenAfterAction())

        case .describeSurroundings:
            return .done(await services.sceneDescriber.describeCurrentScene())

        case .whereAmI:
            let location = await services.locationContext.currentLocationDescription()
            return .done(location ?? "The location isn't available yet.")

        case .repeatLastAnnouncement:
            await services.announcements.repeatLast()
            return .done("The app is repeating its last announcement now. Reply with nothing.")

        case .lookWithCamera(let question):
            let context = await services.locationContext.currentLocationDescription()
            do {
                return .done(try await services.sceneDescriber.ask(question, locationContext: context))
            } catch {
                return .failed((error as? LocalizedError)?.errorDescription ?? "The camera couldn't answer that.")
            }
        }
    }

    /// Nil on success, otherwise why not.
    private func navigate(to destination: AgentDestination) -> String? {
        switch destination {
        case .back:
            guard !router.path.isEmpty else { return "Already on the home screen; there is nothing to go back to." }
            router.pop()
        case .home:
            router.popToRoot()
        case .search:
            push(.search)
        case .settings:
            push(.settings)
        case .callHelp:
            push(.callHelp)
        case .camera:
            push(.feature(.scene))
        }
        return nil
    }

    private func push(_ route: AppRoute) {
        guard router.path.last != route else { return }
        router.push(route)
    }

    private func missing(_ id: String, kind: String) -> String {
        "There is no \(kind) with id \(id) on the screen now. \(screenDescription())"
    }

    private func screenAfterAction() async -> String {
        try? await Task.sleep(for: Self.settleDelay)
        return "Done. \(screenDescription())"
    }

    /// The screen name and its controls, as sent to the model.
    private func screenDescription() -> String {
        let controls = registry.snapshot()
        var text = "Screen: \(screenName)."
        if controls.isEmpty {
            text += " There are no controls listed on this screen."
        } else {
            text += " Controls, top to bottom:\n" + controls.map(\.promptLine).joined(separator: "\n")
        }
        return text
    }

    private var screenName: String {
        switch router.path.last {
        case nil: "Home"
        case .search: "Search destination"
        case .place(let place, _): "Place details for \(place.name)"
        case .routes(let place, _, _): "Route options to \(place.name)"
        case .trip(let plan): "Walking trip to \(plan.place.name)"
        case .settings: "Settings"
        case .callHelp: "Call help (volunteers)"
        case .chat(let volunteer): "Chat with \(volunteer.name)"
        case .developerTools: "Developer tools"
        case .feature(.scene): "Camera guidance"
        case .feature(.trip): "Live trip"
        }
    }

    // MARK: - Helpers

    private func say(_ text: String) async {
        lastReply = text
        await services.announcements.submit(
            AnnouncementEvent(category: .system, priority: .high, text: text, source: .userInteraction)
        )
    }

    private func toolResult(_ id: String, _ text: String, isError: Bool = false) -> JSONValue {
        var block: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(id), "content": .string(text)]
        if isError { block["is_error"] = true }
        return .object(block)
    }

    private func fillPendingResult(_ pending: PendingConfirmation, with text: String) {
        guard let slot = heldResults.firstIndex(where: { $0 == nil }) else { return }
        heldResults[slot] = toolResult(pending.toolUseID, text)
    }

    private func takeHeldResults() -> [JSONValue] {
        defer { heldResults = [] }
        return heldResults.compactMap { $0 }
    }

    private func resetConversation() {
        conversation = []
        heldResults = []
        pending = nil
    }
}
