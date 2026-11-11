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

    @ObservationIgnored private let services: AppServices

    init(services: AppServices) {
        self.services = services
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
