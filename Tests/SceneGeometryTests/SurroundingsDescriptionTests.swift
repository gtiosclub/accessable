import CoreGraphics
import Foundation
import Testing
@testable import SceneGeometry

private func object(
    _ label: String, _ metres: Double?, hazard: Bool = false, confidence: Float = 0.9,
    origin: Detection.Origin = .model, x: CGFloat = 0.4
) -> Detection {
    Detection(label: label, confidence: confidence, boundingBox: CGRect(x: x, y: 0.4, width: 0.2, height: 0.2),
              distance: metres, bearing: .ahead, origin: origin, isHazard: hazard)
}

private func facts(
    _ detections: [Detection] = [], hazards: [ElevationHazard] = [], text: [RecognizedText] = [], labels: [String] = []
) -> ImageFacts {
    var facts = ImageFacts()
    facts.detections = detections
    facts.elevationHazards = hazards
    facts.text = text
    facts.labels = labels
    return facts
}

private struct ScriptedModel: AskAIResponder {
    let reply: String
    func answer(_ question: String, facts: ImageFacts) async throws -> String { reply }
}

private struct FixedExtractor: ImageFactExtracting {
    let facts: ImageFacts
    func facts(from imageData: Data, colorsFor detections: [Detection]) throws -> ImageFacts { facts }
}

private struct ImmediateScheduler: AskAIExtractionScheduling {
    func schedule(_ work: @escaping @Sendable () -> Void) { work() }
}

private func describer(model: String) -> SurroundingsDescriber {
    SurroundingsDescriber(
        model: ScriptedModel(reply: model),
        extractor: FixedExtractor(facts: ImageFacts()),
        extractionScheduler: ImmediateScheduler()
    )
}

/// What the live pipeline saw: the detections and kerbs Ask AI takes from the observation.
private func scene(_ detections: [Detection] = [], hazards: [ElevationHazard] = []) -> SceneObservation {
    SceneObservation(detections: detections, elevationHazards: hazards)
}

@Suite("T21 — Describe my surroundings AI mode")
struct SurroundingsDescriptionTests {
    // MARK: Prompt

    @Test func promptAsksForTheSurroundingsNotAQuestion() {
        let prompt = SurroundingsPrompt.prompt(facts: facts([object("chair", 2)]))
        #expect(prompt.hasSuffix("Request: \(SurroundingsPrompt.request)"))
        #expect(!prompt.contains("Question:"))
    }

    @Test func promptListsHazardsBeforeOtherObjectsByDefault() throws {
        let prompt = SurroundingsPrompt.prompt(facts: facts(
            [object("bench", 4), object("pole", 1.2, hazard: true)],
            hazards: [ElevationHazard(type: .stepDown, distance: 1.5, heightChange: -0.18)]
        ))
        let hazards = try #require(prompt.range(of: "Hazards, steps and obstacles:"))
        let others = try #require(prompt.range(of: "Other objects nearby:"))
        #expect(hazards.lowerBound < others.lowerBound)
        #expect(prompt.lowercased().contains("pole"))
    }

    @Test func promptFollowsTheUsersRanking() throws {
        let found = facts(
            [object("person", 3), object("pole", 1.2, hazard: true)],
            text: [RecognizedText(string: "EXIT", confidence: 0.9, boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.1))]
        )
        let signsFirst = AIPriorities(order: [.signsText, .people, .hazards])
        let prompt = SurroundingsPrompt.prompt(facts: found, priorities: signsFirst)
        let text = try #require(prompt.range(of: "Text in the picture:"))
        let people = try #require(prompt.range(of: "People:"))
        let hazards = try #require(prompt.range(of: "Hazards, steps and obstacles:"))
        #expect(text.lowerBound < people.lowerBound)
        #expect(people.lowerBound < hazards.lowerBound)
    }

    @Test func doorsAreCalledOutNotLostAmongObjects() {
        let prompt = SurroundingsPrompt.prompt(facts: facts([object("door", 3, origin: .mesh), object("plant", 2)]))
        #expect(prompt.contains("Doors, entrances"))
        let doorLine = prompt.split(separator: "\n").first { $0.lowercased().contains("door") && $0.hasPrefix("- ") }
        #expect(doorLine != nil)
    }

    @Test func onlyTheNearestFewOtherObjectsAreListed() {
        let many = (1...8).map { object("plant\($0)", Double($0)) }
        let lines = SurroundingsPrompt.prompt(facts: facts(many)).split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(lines.count == SurroundingsPrompt.maxOtherObjects)
        #expect(lines.first?.lowercased().contains("plant1") == true)
    }

    @Test func aCrowdIsOneLineNotOnePerPerson() {
        let crowd = (0..<5).map { index -> Detection in
            var person = object("person", 3, x: 0.3 + CGFloat(index) * 0.05)
            person.worldPosition = SIMD3(Float(index) * 0.5, 0, -3)
            return person
        }
        let lines = SurroundingsPrompt.prompt(facts: facts(crowd)).split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(lines.count < crowd.count)
    }

    @Test func lowConfidenceObjectsAreMarkedUncertain() {
        let prompt = SurroundingsPrompt.prompt(facts: facts([object("backpack", 2, confidence: 0.4)]))
        #expect(prompt.contains("Uncertain detections"))
        #expect(prompt.contains("backpack"))
    }

    @Test func emptyFactsSayNothingWasFound() {
        let prompt = SurroundingsPrompt.prompt(facts: ImageFacts())
        #expect(prompt.contains("found nothing"))
        #expect(!prompt.contains("Mention these first"))
    }

    @Test func instructionsForbidSafetyClaimsAndInventory() {
        let text = SurroundingsPrompt.instructions.lowercased()
        #expect(text.contains("never say a street"))
        #expect(text.contains("never list everything"))
    }

    // MARK: Offline wording

    @Test func templateUsesTheOfflineDescriptionOverTheSameFacts() {
        let found = facts([object("chair", 2, hazard: true)])
        #expect(SurroundingsTemplate.describe(found) == SceneDescriptionBuilder().describe(
            SceneObservation(detections: found.detections, recognizedText: [], elevationHazards: [])
        ))
        #expect(SurroundingsTemplate.describe(ImageFacts()) == "Nothing detected nearby.")
    }

    // MARK: Describer, with the T24 rules and T23 order applied

    @Test func describerReturnsTheModelsDescription() async throws {
        let response = try await describer(model: "A chair is 2 metres ahead.")
            .describe(imageData: Data([1]), observation: scene([object("chair", 2)]))
        #expect(response.answer == "A chair is 2 metres ahead.")
    }

    @Test func describerKeepsUpToThreeSentencesAndDropsTheRest() async throws {
        let response = try await describer(
            model: "A bench is ahead. A plant is on your left. A table is on your right. A bin is behind."
        ).describe(imageData: Data([1]), observation: scene([object("bench", 4)]))
        #expect(response.answer == "A bench is ahead. A plant is on your left. A table is on your right.")
    }

    @Test func describerNeverSaysAStreetIsSafe() async throws {
        let response = try await describer(model: "A road is ahead. It is safe to cross.")
            .describe(imageData: Data([1]), observation: scene([object("car", 6)]))
        #expect(!response.answer.lowercased().contains("safe to cross"))
        #expect(response.answer.contains("A road is ahead."))
    }

    @Test func describerWarnsOfACloseHazardTheModelLeftOut() async throws {
        let response = try await describer(model: "A bench is ahead.").describe(
            imageData: Data([1]),
            observation: scene([object("bench", 4)], hazards: [ElevationHazard(type: .dropOff, distance: 1, heightChange: -0.5)])
        )
        #expect(response.answer.lowercased().contains("drop"))
        #expect(response.answer.contains("A bench is ahead."))
    }

    @Test func describerSaysNothingNearbyWhenNothingWasFound() async throws {
        let response = try await describer(model: "Something is there.").describe(imageData: Data([1]))
        #expect(response.answer == SurroundingsDescriber.nothingNearby)
    }

    @Test func describerReordersByTheUsersRanking() async throws {
        let settings = AskAISettings(priorities: AIPriorities(order: [.signsText, .hazards]))
        let found = facts(text: [RecognizedText(string: "EXIT", confidence: 0.9, boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.1))])
        let describer = SurroundingsDescriber(
            settings: settings,
            model: ScriptedModel(reply: "A pole is 2 metres ahead. \"EXIT\" is on your left."),
            extractor: FixedExtractor(facts: found),
            extractionScheduler: ImmediateScheduler()
        )
        let answer = try await describer.describe(imageData: Data([1]), observation: scene([object("pole", 2, hazard: true)])).answer
        let sign = try #require(answer.range(of: "\"EXIT\""))
        let pole = try #require(answer.range(of: "pole"))
        #expect(sign.lowerBound < pole.lowerBound)
    }

    @Test func describingTwiceInARowDoesNotRepeatItself() async throws {
        let describer = describer(model: "A bench is ahead.")
        let seen = scene([object("bench", 4)])
        _ = try await describer.describe(imageData: Data([1]), observation: seen)
        let again = try await describer.describe(imageData: Data([1]), observation: seen).answer
        #expect(again.hasPrefix(AskAIPolicy.sameAsBefore))
    }
}
