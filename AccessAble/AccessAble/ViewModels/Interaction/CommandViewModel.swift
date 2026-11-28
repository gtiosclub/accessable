//
//  CommandViewModel.swift
//  AccessAble
//
//  Created by narwhal on 10/13/26.
//


import Foundation
import Observation
import os

private let log = Logger(subsystem: "AccessAble", category: "Commands")
 
/// Owner: User Interaction (3.1). Takes typed or dictated text, interprets it, carries out the command,
/// and speaks the reply.
@MainActor
@Observable
final class CommandViewModel {
    var text = ""
    private(set) var lastReply: String?
    private(set) var isWorking = false
    let dictation = SpeechDictation()
    /// Starts a call with a volunteer; set by the screen, which owns navigation.
    @ObservationIgnored var onCallVolunteer: (() -> Void)?
    /// Opens the place / route-summary screen for a looked-up destination (SEARCH-13).
    @ObservationIgnored var onOpenDestination: ((Destination) -> Void)?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let destinations: DestinationLookup
    @ObservationIgnored private let clock: any Clock<Duration>
    /// The place lookup in flight; cancelled by the next command or leaving the screen.
    @ObservationIgnored private var lookup: Task<DestinationLookupResult, any Error>?
    /// The places just read out, for "number two" or a name; until `choicesExpired` says they're stale.
    @ObservationIgnored private var choices: [Destination] = []
    @ObservationIgnored private var choicesExpired: () -> Bool = { true }

    /// How long the places read out can still be picked by number or name.
    static let choiceLifetime: Duration = .seconds(60)
    /// How long to wait for the trip's state before taking it as no trip.
    static let tripStateWait: Duration = .seconds(1)

    init(services: AppServices, destinations: DestinationLookup, clock: any Clock<Duration> = ContinuousClock()) {
        self.services = services
        self.destinations = destinations
        self.clock = clock
        dictation.onTranscript = { [weak self] transcript, isFinal in
            guard let self else { return }
            text = transcript
            // Stopping dictation (or Speech ending it on its own) runs the command, no extra tap needed
            if isFinal {
                dictation.stop()
                Task { await self.submit() }
            }
        }
        dictation.onError = { [weak self] message in
            Task { await self?.reply(message) }
        }
    }

    var canSubmit: Bool {
        !isWorking && !dictation.isRecording && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func toggleDictation() async {
        if dictation.isRecording {
            dictation.stop()
        } else {
            await dictation.start()
        }
    }

    /// Leaving the screen: stops listening and any place lookup, so nothing opens from a stale screen.
    func cancelDictation() {
        dictation.cancel()
        cancelLookup()
    }

    private func cancelLookup() {
        lookup?.cancel()
        lookup = nil
    }

    func submit() async {
        guard canSubmit else { return }
        let input = text
        text = ""
        await run(input)
    }
 
    func run(_ input: String) async {
        cancelLookup()
        isWorking = true
        defer { isWorking = false }
        if let chosen = takeChoice(for: input) {
            await open(chosen)
            return
        }
        let command = await services.commands.interpret(input)
        await perform(command)
    }
 
    private func perform(_ command: VoiceCommand) async {
        switch command {
        case .describeSurroundings:
            let description = await services.sceneDescriber.describeCurrentScene()
            await reply(description, category: .ambient)
        case .whereAmI:
            let location = await services.locationContext.currentLocationDescription()
            await reply(location ?? "Your location isn't available yet.")
        case .repeatLast:
            await services.announcements.repeatLast()
        case .pauseTrip:
            await services.trip.pauseTrip()
            await reply("Trip paused.")
        case .resumeTrip:
            await services.trip.resumeTrip()
            await reply("Trip resumed.")
        case .endTrip:
            await services.trip.endTrip()
            await reply("Trip ended.")
        case .callVolunteer:
            if let onCallVolunteer {
                onCallVolunteer()
            } else {
                await reply("To call a volunteer, choose Call a volunteer on the Home screen.")
            }
        case .navigate(to: let name):
            await navigate(to: name)
        case .ask(let question) where VisualQuestion.needsCamera(question):
            await askAboutCamera(question)
        case .ask(let question):
            let context = await services.locationContext.currentLocationDescription()
            do {
                await reply(try await services.commands.answer(question, context: context))
            } catch {
                await reply((error as? CommandError)?.spokenMessage ?? CommandError.failed.spokenMessage)
            }
        case .unknown:
            await reply("Sorry, I didn't understand. Try \"describe my surroundings\" or \"where am I\".")
        }
    }

    /// SEARCH-13: look up the spoken place and open its route summary, or speak choices / failure.
    private func navigate(to name: String) async {
        if await isOnATrip() {
            await reply("You're already on a trip. End it first to go somewhere else.")
            return
        }
        if DestinationLookup.normalized(name) == "home" {
            await openHome()
            return
        }
        let task = Task { [destinations] in try await destinations.lookUp(name) }
        lookup = task
        let result: DestinationLookupResult
        do {
            result = try await task.value
        } catch is CancellationError {
            return
        } catch {
            guard !task.isCancelled else { return }
            log.error("Place search failed: \(error.localizedDescription, privacy: .public)")
            await reply(error as? PlaceLookupError == .offline
                ? "I couldn't search right now. Check your connection."
                : "I couldn't search right now.")
            return
        }
        // A newer command or leaving the screen cancelled it: never open a place from a stale lookup.
        guard !task.isCancelled else { return }
        lookup = nil
        switch result {
        case .one(let destination):
            await open(destination)
        case .several(let destinations):
            choices = destinations
            choicesExpired = clock.hasPassed(Self.choiceLifetime)
            let numbered = destinations.enumerated().map { "\($0.offset + 1), \($0.element.name)" }
            await reply("I found \(destinations.count) places: \(numbered.joined(separator: "; ")). Say the number or the name.")
        case .none:
            await reply("I couldn't find \(name).")
        }
    }

    private func openHome() async {
        if let home = await destinations.home() {
            await open(home)
        } else {
            await reply("You haven't saved a place called Home.")
        }
    }

    private func open(_ destination: Destination) async {
        if let onOpenDestination {
            onOpenDestination(destination)
        } else {
            await reply("Open Commands from Home to go to \(destination.name).")
        }
    }

    /// The place read out that `input` picks ("the first one", "number two", "2", its name), if any.
    /// Any utterance forgets the places read out.
    private func takeChoice(for input: String) -> Destination? {
        let choices = choices
        self.choices = []
        guard !choices.isEmpty, !choicesExpired() else { return nil }
        let spoken = DestinationLookup.normalized(KeywordCommandInterpreter.navigateDestination(in: input) ?? input)
        if let number = Self.choiceNumber(in: spoken), choices.indices.contains(number - 1) {
            return choices[number - 1]
        }
        guard !spoken.isEmpty else { return nil }
        let names = choices.map { DestinationLookup.normalized($0.name) }
        if let exact = names.firstIndex(of: spoken) { return choices[exact] }
        let containing = names.indices.filter { names[$0].contains(spoken) }
        return containing.count == 1 ? choices[containing[0]] : nil
    }

    /// 1-based number in "the first one", "number two", "2"; nil if that's not all that was said.
    private static func choiceNumber(in spoken: String) -> Int? {
        let fillers: Set = ["the", "number", "option", "choice", "please"]
        var words = spoken.split(separator: " ").map(String.init).filter { !fillers.contains($0) }
        if words.count == 2, words[1] == "one" { words.removeLast() }
        guard words.count == 1 else { return nil }
        let numbers = [["1", "one", "first"], ["2", "two", "second"], ["3", "three", "third"]]
        return numbers.firstIndex { $0.contains(words[0]) }.map { $0 + 1 }
    }

    /// The trip's current state (the stream replays it); taken as no trip if none arrives in time.
    private func isOnATrip() async -> Bool {
        let trip = services.trip
        let clock = clock
        let wait = Self.tripStateWait
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                for await state in trip.tripStates() {
                    return state.phase == .active || state.phase == .paused
                }
                return false
            }
            group.addTask {
                try? await clock.sleep(for: wait)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
    }
 
    /// T38: a question about what the camera sees goes to Ask AI with a fresh camera frame and
    /// what the obstacle pipeline last found, not to the text-only assistant, which can't see
    /// and would guess. Runs beside obstacle detection, which keeps warning while this waits.
    private func askAboutCamera(_ question: String) async {
        let context = await services.locationContext.currentLocationDescription()
        do {
            let answer = try await services.sceneDescriber.ask(question, locationContext: context)
            await reply(answer, category: .ambient)
        } catch {
            // Not the text assistant as a fallback: without the camera it would make things up.
            let message = (error as? LocalizedError)?.errorDescription ?? "Sorry, I couldn't look at the camera. Please try again."
            await reply(message)
        }
    }

    /// Shows the reply on screen and speaks it through the AnnouncementEngine (so it's VoiceOver-safe).
    /// `.userInteraction` source means it skips the category filter and dedup: the user asked for it.
    private func reply(_ text: String, category: AnnouncementCategory = .system) async {
        lastReply = text
        await services.announcements.submit(
            AnnouncementEvent(category: category, priority: .high, text: text, source: .userInteraction)
        )
    }
}

private extension Clock where Duration == Swift.Duration {
    /// Whether `duration` from now has passed, asked later.
    func hasPassed(_ duration: Duration) -> () -> Bool {
        let deadline = now.advanced(by: duration)
        return { self.now >= deadline }
    }
}
