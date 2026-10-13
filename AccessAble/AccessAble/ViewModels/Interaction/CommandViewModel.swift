import Foundation
import Observation
 
/// Owner: User Interaction (3.1). Takes typed text, interprets it, carries out the command, and speaks the reply.
/// Voice input (speech recognition) can call `run(_:)` directly later.
@MainActor
@Observable
final class CommandViewModel {
    var text = ""
    private(set) var lastReply: String?
    private(set) var isWorking = false
 
    @ObservationIgnored private let services: AppServices
 
    init(services: AppServices) {
        self.services = services
    }
 
    var canSubmit: Bool {
        !isWorking && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            await reply(description, category: .ambient, source: .sceneDescription)
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
 
    /// Shows the reply on screen and speaks it through the AnnouncementEngine (so it's VoiceOver-safe).
    private func reply(
        _ text: String,
        category: AnnouncementCategory = .system,
        source: AnnouncementSource = .userInteraction
    ) async {
        lastReply = text
        await services.announcements.submit(
            AnnouncementEvent(category: category, priority: .high, text: text, source: source)
        )
    }
}
