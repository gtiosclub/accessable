//
//  CommandViewModel.swift
//  AccessAble
//
//  Created by narwhal on 10/13/26.
//


import Foundation
import Observation
 
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

    init(services: AppServices, destinations: DestinationLookup? = nil) {
        self.services = services
        self.destinations = destinations ?? DestinationLookup(
            nicknames: CampusNicknameDictionary.bundled,
            saved: SavedPlacesDestinationSource { _ in [] },
            mapKit: MapKitDestinationSource(region: .georgiaTech)
        )
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

    func cancelDictation() {
        dictation.cancel()
    }

    func submit() async {
        guard canSubmit else { return }
        let input = text
        text = ""
        await run(input)
    }
 
    func run(_ input: String) async {
        isWorking = true
        defer { isWorking = false }
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
        switch await destinations.lookUp(name) {
        case .one(let destination):
            if let onOpenDestination {
                onOpenDestination(destination)
            } else {
                await reply("Open Commands from Home to go to \(destination.name).")
            }
        case .several(let destinations):
            let list = Self.spokenList(destinations.map(\.name))
            await reply("I found \(list). Say take me to one of those.")
        case .none:
            await reply("I couldn't find \(name).")
        }
    }

    private func isOnATrip() async -> Bool {
        for await state in services.trip.tripStates() {
            return state.phase == .active || state.phase == .paused
        }
        return false
    }

    private static func spokenList(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default:
            names.dropLast().joined(separator: ", ") + ", and \(names.last!)"
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
