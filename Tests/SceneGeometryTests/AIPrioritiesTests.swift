import CoreGraphics
import Foundation
import Testing
@testable import SceneGeometry

private func object(_ label: String, _ metres: Double, hazard: Bool = false) -> Detection {
    Detection(label: label, confidence: 0.9, boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
              distance: metres, bearing: .ahead, origin: .model, isHazard: hazard)
}

private let scene: ImageFacts = {
    var facts = ImageFacts()
    facts.detections = [object("bench", 3, hazard: true), object("person", 2), object("cup", 1)]
    facts.text = [RecognizedText(string: "EXIT", confidence: 0.9, boundingBox: CGRect(x: 0.7, y: 0.1, width: 0.1, height: 0.05))]
    facts.labels = ["hallway"]
    return facts
}()

private let answer = "A bench is 3 metres ahead. A person is 2 metres ahead. \"EXIT\" is high up on your right."

private struct ScriptedModel: AskAIResponder {
    let reply: String
    func answer(_ question: String, facts: ImageFacts) async throws -> String { reply }
}

@Suite("T23 — Ask AI priorities")
struct AIPrioritiesTests {
    @Test func defaultFollowsTheTaskOrder() {
        #expect(AIPriorities.default.order == [.hazards, .navigation, .people, .signsText, .landmarks])
    }

    @Test func alwaysHoldsEveryCategoryOnce() {
        #expect(AIPriorities(order: [.people, .people]).order == [.people, .hazards, .navigation, .signsText, .landmarks])
    }

    @Test func moveStaysInBounds() {
        var priorities = AIPriorities.default
        priorities.move(.people, by: -1)
        #expect(priorities.order == [.hazards, .people, .navigation, .signsText, .landmarks])
        priorities.move(.hazards, by: -5)
        #expect(priorities.order.first == .hazards)
        priorities.move(.hazards, by: 10)
        #expect(priorities.order.last == .hazards)
    }

    @Test func dragReordersLikeSwiftUI() {
        var down = AIPriorities.default   // hazards, navigation, people, signsText, landmarks
        down.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(down.order == [.navigation, .people, .hazards, .signsText, .landmarks])

        var up = AIPriorities.default
        up.move(fromOffsets: IndexSet(integer: 4), toOffset: 1)
        #expect(up.order == [.hazards, .landmarks, .navigation, .people, .signsText])

        var toEnd = AIPriorities.default
        toEnd.move(fromOffsets: IndexSet(integer: 1), toOffset: 5)
        #expect(toEnd.order == [.hazards, .people, .signsText, .landmarks, .navigation])

        var same = AIPriorities.default
        same.move(fromOffsets: IndexSet(integer: 2), toOffset: 3)
        #expect(same == .default)

        var several = AIPriorities.default
        several.move(fromOffsets: IndexSet([0, 1]), toOffset: 4)
        #expect(several.order == [.people, .signsText, .hazards, .navigation, .landmarks])
    }

    @Test func decodesOldOrUnknownRankingsSafely() throws {
        let json = #"{"order": ["signsText", "elevators"]}"#
        let decoded = try JSONDecoder().decode(AIPriorities.self, from: Data(json.utf8))
        #expect(decoded.order == [.signsText, .hazards, .navigation, .people, .landmarks])
        let roundTrip = try JSONDecoder().decode(AIPriorities.self, from: JSONEncoder().encode(decoded))
        #expect(roundTrip == decoded)
    }

    @Test func classifiesSentencesFromTheFacts() {
        #expect(AIPriorities.categories(of: "A bench is 3 metres ahead.", facts: scene) == [.hazards])
        #expect(AIPriorities.categories(of: "Someone is on your left.", facts: scene) == [.people])
        #expect(AIPriorities.categories(of: "The EXIT sign is on your right.", facts: scene) == [.signsText])
        #expect(AIPriorities.categories(of: "This looks like a hallway.", facts: scene) == [.landmarks])
        #expect(AIPriorities.categories(of: "Turn left onto the street.", facts: scene) == [.navigation])
        #expect(AIPriorities.categories(of: "A cup is on the table.", facts: scene).isEmpty)
    }

    @Test func reordersByTheUsersRanking() {
        let peopleFirst = AIPriorities(order: [.people, .signsText])
        #expect(peopleFirst.ordered(AskAIPolicy.sentences(in: answer), facts: scene) == [
            "A person is 2 metres ahead.", "\"EXIT\" is high up on your right.", "A bench is 3 metres ahead.",
        ])
    }

    @Test func aFollowUpSentenceStaysWithItsSubject() {
        let sentences = ["A cup is on the table.", "A person is 2 metres ahead.", "They look tall."]
        #expect(AIPriorities(order: [.people]).ordered(sentences, facts: scene) == [
            "A person is 2 metres ahead.", "They look tall.", "A cup is on the table.",
        ])
    }

    @Test func rankingDecidesWhatSurvivesTheLengthCap() {
        let signsFirst = AIPriorities(order: [.signsText, .people])
        let result = AskAIPolicy().apply(answer, question: "What's around me?", facts: scene, priorities: signsFirst)
        #expect(result.answer == "\"EXIT\" is high up on your right. A person is 2 metres ahead.")
    }

    @Test func closeHazardsStillComeFirst() {
        var facts = scene
        facts.elevationHazards = [ElevationHazard(type: .dropOff, distance: 1, heightChange: -0.5)]
        let result = AskAIPolicy().apply(answer, question: "q", facts: facts, priorities: AIPriorities(order: [.signsText]))
        #expect(result.answer.hasPrefix("Drop-off 1 metre ahead. \"EXIT\""))
    }

    @Test func promptListsSectionsInTheUsersOrder() throws {
        let prompt = AskAIRules.prompt(question: "q", facts: scene, priorities: AIPriorities(order: [.signsText, .people]))
        #expect(prompt.contains("in this order: signs and text, people, hazards"))
        let text = try #require(prompt.range(of: "Text in the picture:"))
        let people = try #require(prompt.range(of: "People:"))
        let hazards = try #require(prompt.range(of: "Hazards and obstacles:"))
        let others = try #require(prompt.range(of: "Other objects:"))
        #expect(text.lowerBound < people.lowerBound && people.lowerBound < hazards.lowerBound && hazards.lowerBound < others.lowerBound)
        #expect(prompt.hasSuffix("Question: q"))
    }

    @Test func copiedHeadingsAreRemoved() {
        #expect(AskAIPolicy.withoutHeading("People: Person slightly left, 2.5 metres.") == "Person slightly left, 2.5 metres.")
        #expect(AskAIPolicy.withoutHeading("Text: \"EXIT\" on your right.") == "\"EXIT\" on your right.")
        #expect(AskAIPolicy.withoutHeading("The sign reads: EXIT.") == "The sign reads: EXIT.")
    }

    @Test func responderReadsTheCurrentSettings() async throws {
        let settings = AskAISettings()
        let responder = RuledAskAIResponder(settings: settings, model: ScriptedModel(reply: answer))
        settings.priorities = AIPriorities(order: [.signsText])
        #expect(try await responder.answer("What's here?", facts: scene).hasPrefix("\"EXIT\""))
    }
}
