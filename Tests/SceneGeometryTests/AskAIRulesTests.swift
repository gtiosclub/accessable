import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import SceneGeometry

private func object(_ label: String, _ metres: Double?, hazard: Bool = false, confidence: Float = 0.9) -> Detection {
    Detection(label: label, confidence: confidence, boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
              distance: metres, bearing: .ahead, origin: .model, isHazard: hazard)
}

private func facts(_ detections: [Detection] = [], hazards: [ElevationHazard] = []) -> ImageFacts {
    var facts = ImageFacts()
    facts.detections = detections
    facts.elevationHazards = hazards
    return facts
}

private let policy = AskAIPolicy()
private let someFacts = facts([object("bench", 4)])

/// Returns a scripted answer, standing in for the on-device model.
private struct ScriptedModel: AskAIResponder {
    let reply: String
    func answer(_ question: String, facts: ImageFacts) async throws -> String { reply }
}

@Suite("T24 — Ask AI safety and response rules")
struct AskAIRulesTests {
    // MARK: Never says a street is safe to cross

    @Test(arguments: [
        "It's safe to cross now.",
        "You can cross the street.",
        "The crosswalk is clear.",
        "It looks clear, go ahead.",
        "There is no traffic, so it is okay to cross.",
    ])
    func dropsSafetyClaims(_ claim: String) {
        #expect(AskAIPolicy.claimsSafety(claim))
        let result = policy.apply("There is a crosswalk ahead. \(claim)", question: "Can I cross?", facts: someFacts)
        #expect(!result.answer.contains(claim))
        #expect(result.answer.contains(AskAIPolicy.crossingCaveat))
        #expect(result.answer.contains("There is a crosswalk ahead."))
    }

    @Test(arguments: [
        "I can't tell if it's safe to cross.",
        "It is not safe to cross here.",
        "Never cross without checking the signal.",
        "A chair is 2 metres ahead.",
    ])
    func keepsWarningsAndOrdinaryAnswers(_ sentence: String) {
        #expect(!AskAIPolicy.claimsSafety(sentence))
    }

    @Test func crossingQuestionsAlwaysGetTheCaveat() {
        #expect(AskAIPolicy.asksAboutCrossing("Is it safe to cross the street?"))
        #expect(AskAIPolicy.asksAboutCrossing("where is the crosswalk"))
        #expect(!AskAIPolicy.asksAboutCrossing("What colour is the chair?"))
        let answer = policy.apply("A bench is 4 metres ahead.", question: "Is it safe to cross?", facts: someFacts).answer
        #expect(answer == "\(AskAIPolicy.crossingCaveat) A bench is 4 metres ahead.")
    }

    // MARK: Says when it is unsure

    @Test func nothingFoundMeansCannotTellWhateverTheModelSays() {
        let answer = policy.apply("Room 210 is on your left.", question: "Where is room 210?", facts: ImageFacts()).answer
        #expect(answer == AskAIPolicy.cannotTell)
    }

    @Test func emptyAnswerMeansCannotTell() {
        #expect(policy.apply("", question: "What is that?", facts: someFacts).answer == AskAIPolicy.cannotTell)
    }

    @Test func uncertainDetectionsAreFlaggedToTheModel() {
        let prompt = AskAIRules.prompt(question: "What is on the table?", facts: facts([object("vase", 2, confidence: 0.55), object("chair", 2)]))
        #expect(prompt.hasPrefix("Uncertain detections, say they might be there: vase."))
        #expect(!AskAIRules.prompt(question: "q", facts: facts([object("chair", 2)])).contains("Uncertain"))
    }

    // MARK: Keeps answers short

    @Test func capsTheNumberOfSentences() {
        let answer = policy.apply("One thing. Two things. Three things. Four things.", question: "What's here?", facts: someFacts).answer
        #expect(answer == "One thing. Two things.")
    }

    @Test func capsWordsByDroppingWholeSentences() {
        let long = Array(repeating: "word", count: 38).joined(separator: " ") + "."
        let answer = policy.apply("\(long) A chair is 2 metres ahead.", question: "What's here?", facts: someFacts).answer
        #expect(answer == long)
    }

    @Test func keepsDecimalDistancesInOneSentence() {
        #expect(AskAIPolicy.sentences(in: "A chair is 2.5 metres ahead. A door is on your left") == [
            "A chair is 2.5 metres ahead.", "A door is on your left.",
        ])
    }

    // MARK: Urgent hazards first

    @Test func prependsACloseDropOffTheAnswerLeftOut() {
        let found = facts([object("bench", 4)], hazards: [ElevationHazard(type: .dropOff, distance: 1.5, heightChange: -0.4)])
        let answer = policy.apply("A bench is 4 metres ahead.", question: "What's ahead?", facts: found).answer
        #expect(answer == "Drop-off 1.5 metres ahead. A bench is 4 metres ahead.")
    }

    @Test func doesNotRepeatAHazardTheAnswerAlreadyMentions() {
        let found = facts(hazards: [ElevationHazard(type: .stepDown, distance: 1, heightChange: -0.15)])
        let answer = policy.apply("There is a step down 1 metre ahead.", question: "What's ahead?", facts: found).answer
        #expect(answer == "There is a step down 1 metre ahead.")
    }

    @Test func prependsACloseObstacleButNotAFarOne() {
        let close = facts([object("chair", 1, hazard: true), object("door", 3)])
        #expect(policy.apply("A door is 3 metres ahead.", question: "Where is the door?", facts: close).answer
            == "Chair 1 metre ahead. A door is 3 metres ahead.")
        let far = facts([object("chair", 3, hazard: true)])
        #expect(policy.apply("Nothing else.", question: "q", facts: far).answer == "Nothing else.")
    }

    // MARK: No repeating

    @Test func repeatedAnswerWithinTheWindowIsShortened() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 0))
        let reply = "A bench is 4 metres ahead. A cup is on the bench."
        let responder = RuledAskAIResponder(model: ScriptedModel(reply: reply), now: { clock.withLock { $0 } })

        #expect(try await responder.answer("What's ahead?", facts: someFacts) == reply)
        #expect(try await responder.answer("What's ahead?", facts: someFacts) == "Same as before: A bench is 4 metres ahead.")

        clock.withLock { $0 += 31 }
        #expect(try await responder.answer("What's ahead?", facts: someFacts) == reply)
    }

    @Test func onlyTheNewPartIsSpoken() {
        let said: Set = [AskAIPolicy.normalized("A bench is 4 metres ahead.")]
        let answer = policy.apply("A bench is 4 metres ahead. A sign says Exit.", question: "q", facts: someFacts, recentlySaid: said)
        #expect(answer.answer == "A sign says Exit.")
        #expect(answer.newlySaid == ["a sign says exit"])
    }

    @Test func hazardsRepeatEvenIfJustSaid() async throws {
        let found = facts(hazards: [ElevationHazard(type: .dropOff, distance: 1, heightChange: -0.5)])
        let responder = RuledAskAIResponder(model: ScriptedModel(reply: "I can't tell from this picture."))
        _ = try await responder.answer("What's ahead?", facts: found)
        #expect(try await responder.answer("What's ahead?", facts: found).hasPrefix("Drop-off 1 metre ahead."))
    }

    // MARK: Fallback

    @Test func templatePathFollowsTheRulesToo() async throws {
        let found = facts([object("chair", 1, hazard: true)])
        let answer = try await RuledAskAIResponder(model: TemplateResponder()).answer("Is it safe to cross?", facts: found)
        #expect(answer.contains(AskAIPolicy.crossingCaveat))
        #expect(!AskAIPolicy.sentences(in: answer).contains(where: AskAIPolicy.claimsSafety))
    }
}

private struct TemplateResponder: AskAIResponder {
    func answer(_ question: String, facts: ImageFacts) async throws -> String {
        TemplateAskAIResponder().answer(question, facts: facts)
    }
}
