import CoreGraphics
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// T21: the "Describe my surroundings" AI mode. Ask AI answers a question; this answers the
// one question that needs no asking, "what is around me?", with a prompt of its own: the
// few things that matter first (hazards, people, doors, stairs, signs), not an inventory.
//
// It reuses Ask AI's grounded facts (T19), the user's ranking (T23) and the response rules
// (T24), so it cannot invent anything, keeps short and never calls a street safe. The offline
// "Describe my surroundings" (T18, `SceneDescriptionBuilder`) stays the answer where Apple
// Intelligence is unavailable.

/// What the on-device model is told in the surroundings mode.
enum SurroundingsPrompt {
    /// Stands in for the user's question, which this mode does not have.
    static let request = "Describe what is immediately around me."

    static let instructions = """
        You help a blind or low-vision person know what is immediately around them. \
        You cannot see the picture. You get a list of what on-device vision found: \
        objects, people, doors and ground hazards with their direction and distance, \
        text and where it is, and what the scene probably contains.
        Rules:
        - Describe only what matters for moving safely: close hazards, steps and drop-offs, \
        people and crowds, doors and entrances, signs, then other nearby objects. \
        Skip anything minor or far away. Never list everything.
        - Answer in two or three short sentences, under 45 words, using only that list.
        - Say where each thing is: ahead, on your left, on your right, and how far when known.
        - If a hazard is close ahead, mention it first.
        - Items marked uncertain, and colours, are estimates: say something might be there.
        - If the list is empty, say nothing was detected nearby. \
        Never guess room numbers, signs or objects that are not in the list.
        - Never say a street, crossing or path is safe or clear. You cannot judge traffic.
        - Speak in plain sentences. Don't copy the list's headings or dashes.
        """

    /// Detections below this are passed on as uncertain, as in `AskAIRules`.
    static let uncertainBelow = AskAIRules.uncertainBelow
    /// Objects that are neither hazards, people nor doors: the nearest few only.
    static let maxOtherObjects = 3

    /// The facts grouped by `AIInfoCategory` in the user's order (T23); doors and entrances
    /// sit with landmarks. Groups of people are collapsed into one line (T35) so a crowd
    /// does not use up the model's few sentences.
    static func prompt(facts: ImageFacts, priorities: AIPriorities = .default) -> String {
        var lines: [String] = []
        let uncertain = facts.detections
            .filter { $0.origin != .geometric && $0.confidence < uncertainBelow }
            .map(\.label)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if !uncertain.isEmpty {
            lines.append("Uncertain detections, say they might be there: \(uncertain.joined(separator: ", ")).")
        }
        if facts.isEmpty {
            lines.append("Vision found nothing it could read or recognize around the user.")
        } else {
            lines.append("Mention these first, in this order: \(priorities.order.map { $0.displayName.lowercased() }.joined(separator: ", ")).")
        }

        func describe(_ detection: Detection) -> String {
            let color = facts.detectionColors[detection.id].map { " Main colour: \($0)." } ?? ""
            return "- \(SpokenPhrasing.describe(detection))\(color)"
        }
        let crowds = detectCrowds(among: facts.detections.filter { $0.label == "person" })
        let doors = facts.detections.filter(isDoor)
        let others = facts.detections
            .filter { !$0.isHazard && $0.label != "person" && !isDoor($0) && $0.origin != .mesh }
            .sorted { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }
            .prefix(maxOtherObjects)

        let hazards = facts.elevationHazards.map { "- \(SpokenPhrasing.describe($0))" }
            + facts.detections.filter { $0.isHazard && $0.label != "person" && !isDoor($0) }.map(describe)
        var people = crowds.crowds.map { "- \(SpokenPhrasing.describe($0))" }
            + facts.detections.filter { $0.label == "person" && !crowds.groupedIDs.contains($0.id) }.map(describe)
        if !facts.people.isEmpty {
            people.append("- \(facts.people.count) seen in the picture, \(facts.people.map { AskAIPrompt.position(of: $0) }.joined(separator: "; ")).")
        }
        let text = facts.text.map { "- \"\($0.string)\", \(AskAIPrompt.position(of: $0.boundingBox))" }
        var landmarks = doors.map(describe)
        if !facts.labels.isEmpty {
            landmarks.append("- Whole-picture guesses, no position: \(facts.labels.joined(separator: ", ")).")
        }
        let sections: [AIInfoCategory: (title: String, lines: [String])] = [
            .hazards: ("Hazards, steps and obstacles:", hazards),
            .people: ("People:", people),
            .signsText: ("Text in the picture:", text),
            .landmarks: ("Doors, entrances and what the scene probably contains:", landmarks),
        ]
        for category in priorities.order {
            guard let section = sections[category], !section.lines.isEmpty else { continue }
            lines.append(section.title)
            lines += section.lines
        }
        if !others.isEmpty {
            lines.append("Other objects nearby:")
            lines += others.map(describe)
        }
        lines.append("")
        lines.append("Request: \(request)")
        return lines.joined(separator: "\n")
    }

    static func isDoor(_ detection: Detection) -> Bool {
        detection.label.lowercased() == "door"
    }
}

/// The surroundings description as the offline T18 builder words it, over the same facts.
/// The answer where the on-device model is unavailable or fails.
enum SurroundingsTemplate {
    static func describe(_ facts: ImageFacts) -> String {
        SceneDescriptionBuilder().describe(SceneObservation(
            detections: facts.detections,
            recognizedText: facts.text,
            elevationHazards: facts.elevationHazards
        ))
    }
}

/// The on-device model with the surroundings prompt and the user's T23 ranking; the T18
/// wording where Apple Intelligence is unavailable or the model fails. Ignores the
/// question: there is only one thing to ask.
struct SurroundingsResponder: AskAIResponder {
    var settings = AskAISettings()

    func answer(_ question: String, facts: ImageFacts) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *), SystemLanguageModel.default.isAvailable {
            do {
                let session = LanguageModelSession(instructions: SurroundingsPrompt.instructions)
                return try await session.respond(
                    to: SurroundingsPrompt.prompt(facts: facts, priorities: settings.priorities)
                ).content
            } catch {
                try Task.checkCancellation()
            }
        }
        #endif
        return SurroundingsTemplate.describe(facts)
    }
}

/// "Describe my surroundings", AI mode (T21): one still image plus what the live pipeline
/// last saw, described on the device under the T23 ranking and the T24 rules.
struct SurroundingsDescriber: Sendable {
    /// Said when nothing was found, in place of T24's "I can't tell from this picture."
    static let nothingNearby = "Nothing detected nearby."

    /// A surroundings description is a little longer than an answer, still short (T24).
    static let policy = AskAIPolicy(maxSentences: 3, maxWords: 45)

    private let askAI: AskAI

    /// `model` defaults to the on-device model reading `settings`; the extractor and
    /// scheduler are seams for tests.
    init(
        settings: AskAISettings = AskAISettings(),
        model: (any AskAIResponder)? = nil,
        extractor: (any ImageFactExtracting)? = nil,
        extractionScheduler: (any AskAIExtractionScheduling)? = nil
    ) {
        var askAI = AskAI(responder: RuledAskAIResponder(
            settings: settings,
            model: model ?? SurroundingsResponder(settings: settings),
            policy: Self.policy
        ))
        if let extractor { askAI.extractor = extractor }
        if let extractionScheduler { askAI.extractionScheduler = extractionScheduler }
        self.askAI = askAI
    }

    func describe(imageData: Data, observation: SceneObservation = .empty) async throws -> AskAIResponse {
        let response = try await askAI.answer(SurroundingsPrompt.request, imageData: imageData, observation: observation)
        guard response.answer == AskAIPolicy.cannotTell else { return response }
        return AskAIResponse(answer: Self.nothingNearby, latencyMilliseconds: response.latencyMilliseconds)
    }
}
