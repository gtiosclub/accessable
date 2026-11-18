import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import SceneGeometry

private let klaus = PlaceLandmark(name: "Klaus", bearing: RelativeBearing(degrees: -90), distance: 40)
private let ferst = PlaceContext(street: "Ferst Drive", heading: 0, landmarks: [klaus])

private func hazardScene(_ metres: Double = 1) -> SceneObservation {
    SceneObservation(elevationHazards: [ElevationHazard(type: .dropOff, distance: Float(metres), heightChange: -0.5)])
}

private struct ScriptedLocation: LocationResponding {
    let reply: String
    func answer(context: PlaceContext, facts: ImageFacts) async throws -> String { reply }
}

private func narrator(_ reply: String, settings: AskAISettings = AskAISettings()) -> LocationNarrator {
    LocationNarrator(settings: settings, responder: ScriptedLocation(reply: reply))
}

@Suite("T22 — Describe my location AI mode")
struct LocationDescriptionTests {
    // MARK: Input

    @Test(arguments: [
        (0.0, CompassPoint.north), (44.0, .northeast), (90.0, .east), (180.0, .south),
        (271.0, .west), (359.0, .north), (-45.0, .northwest), (405.0, .northeast),
    ])
    func headingsBecomeCompassPoints(_ heading: Double, _ point: CompassPoint) {
        #expect(CompassPoint(heading: heading) == point)
    }

    @Test func aMapBearingBecomesAnotherRelativeToWhereYouFace() {
        // Facing east, a place due north is on the left.
        let place = PlaceLandmark(name: "Klaus", compassBearing: 0, heading: 90, distance: 40)
        #expect(place.bearing?.degrees == -90)
        #expect(place.bearing?.side == .left)
    }

    @Test func contextWithNothingInItIsEmpty() {
        #expect(PlaceContext().isEmpty)
        #expect(!PlaceContext(street: "Ferst Drive").isEmpty)
    }

    // MARK: Prompt

    @Test func promptHasTheStreetHeadingAndLandmarks() {
        let prompt = LocationPrompt.prompt(context: ferst, facts: ImageFacts())
        #expect(prompt.contains("Street: Ferst Drive."))
        #expect(prompt.contains("Facing north."))
        #expect(prompt.contains("Klaus"))
        #expect(prompt.hasSuffix("Request: \(LocationPrompt.request)"))
    }

    @Test func promptKeepsOnlyTheNearestLandmarks() {
        let many = (1...6).map { PlaceLandmark(name: "Hall\($0)", distance: Double($0 * 10)) }
        let lines = LocationPrompt.prompt(context: PlaceContext(street: "Ferst Drive", landmarks: many.reversed()), facts: ImageFacts())
            .split(separator: "\n").filter { $0.hasPrefix("- Hall") }
        #expect(lines.count == LocationPrompt.maxLandmarks)
        #expect(lines.first?.contains("Hall1") == true)
    }

    @Test func promptMarksARoughPosition() {
        let rough = PlaceContext(street: "Ferst Drive", positionAccuracy: 80)
        #expect(LocationPrompt.prompt(context: rough, facts: ImageFacts()).contains("off by up to about 80 metres"))
        let good = PlaceContext(street: "Ferst Drive", positionAccuracy: 8)
        #expect(!LocationPrompt.prompt(context: good, facts: ImageFacts()).contains("rough"))
    }

    @Test func promptAddsWhatTheCameraSees() {
        var facts = ImageFacts()
        facts.elevationHazards = [ElevationHazard(type: .stepDown, distance: 1.5, heightChange: -0.18)]
        facts.text = [RecognizedText(string: "KLAUS", confidence: 0.9, boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.1))]
        let prompt = LocationPrompt.prompt(context: ferst, facts: facts)
        #expect(prompt.contains("Hazards the camera sees:"))
        #expect(prompt.contains("\"KLAUS\""))
    }

    @Test func promptAdmitsWhenNothingIsKnown() {
        #expect(LocationPrompt.prompt(context: PlaceContext(), facts: ImageFacts()).contains("could not tell where"))
    }

    @Test func instructionsForbidGuessingStreetsAndSafetyClaims() {
        let text = LocationPrompt.instructions.lowercased()
        #expect(text.contains("never guess street names"))
        #expect(text.contains("never say a street"))
    }

    // MARK: Offline wording

    @Test func templateSaysTheExampleAnswer() {
        #expect(LocationTemplate.describe(context: ferst) == "You're on Ferst Drive facing north. Klaus is on your left, 40 metres.")
    }

    @Test func templateAdmitsWhatItDoesNotKnow() {
        #expect(LocationTemplate.describe(context: PlaceContext()) == LocationTemplate.cannotTell)
        #expect(LocationTemplate.describe(context: PlaceContext(heading: 90)).contains("can't tell which street"))
        #expect(LocationTemplate.describe(context: PlaceContext(street: "Ferst Drive")) == "You're on Ferst Drive.")
    }

    @Test func templateWarnsWhenThePositionIsRough() {
        #expect(LocationTemplate.describe(context: PlaceContext(street: "Ferst Drive", positionAccuracy: 60)).contains("off by about 60 metres"))
    }

    // MARK: Narrator, with the T24 rules and T23 order applied

    @Test func narratorReturnsTheModelsAnswer() async throws {
        let answer = try await narrator("You're on Ferst Drive facing north. Klaus is ahead on your left.")
            .describe(context: ferst)
        #expect(answer == "You're on Ferst Drive facing north. Klaus is ahead on your left.")
    }

    @Test func narratorCannotTellWithNoContext() async throws {
        #expect(try await narrator("You're somewhere.").describe(context: PlaceContext()) == LocationTemplate.cannotTell)
    }

    @Test func narratorNeverSaysAStreetIsSafe() async throws {
        let answer = try await narrator("You're on Ferst Drive. It is safe to cross.").describe(context: ferst)
        #expect(!answer.lowercased().contains("safe to cross"))
        #expect(answer.contains("You're on Ferst Drive."))
    }

    @Test func narratorKeepsToThreeSentences() async throws {
        let answer = try await narrator("You're on Ferst Drive. Klaus is ahead. Clough is left. Skiles is right.")
            .describe(context: ferst)
        #expect(!answer.contains("Skiles"))
    }

    @Test func narratorWarnsOfACloseHazardTheModelLeftOut() async throws {
        let answer = try await narrator("You're on Ferst Drive facing north.")
            .describe(context: ferst, observation: hazardScene())
        #expect(answer.lowercased().contains("drop"))
        #expect(answer.contains("Ferst Drive"))
    }

    @Test func narratorShortensARepeat() async throws {
        let narrator = narrator("You're on Ferst Drive facing north.")
        _ = try await narrator.describe(context: ferst)
        let again = try await narrator.describe(context: ferst)
        #expect(again.hasPrefix(AskAIPolicy.sameAsBefore))
    }

    @Test func narratorRepeatsAfterTheWindow() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 0))
        let narrator = LocationNarrator(responder: ScriptedLocation(reply: "You're on Ferst Drive."), now: { clock.withLock { $0 } })
        _ = try await narrator.describe(context: ferst)
        clock.withLock { $0 = Date(timeIntervalSince1970: 120) }
        #expect(try await narrator.describe(context: ferst) == "You're on Ferst Drive.")
    }

    @Test func narratorKeepsTheStreetFirstWhateverIsRanked() async throws {
        let settings = AskAISettings(priorities: AIPriorities(order: [.landmarks, .navigation]))
        let answer = try await narrator("You're on Ferst Drive. Klaus is ahead on your left.", settings: settings)
            .describe(context: ferst)
        #expect(answer.hasPrefix("You're on Ferst Drive."))
    }

    @Test func narratorOrdersByTheUsersRanking() async throws {
        let settings = AskAISettings(priorities: AIPriorities(order: [.signsText, .landmarks]))
        let sign = RecognizedText(string: "Room 210", confidence: 0.9, boundingBox: CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.1))
        let answer = try await narrator("Klaus is ahead on your left. The sign says Room 210.", settings: settings)
            .describe(context: ferst, observation: SceneObservation(recognizedText: [sign]))
        let signAt = try #require(answer.range(of: "sign"))
        let klausAt = try #require(answer.range(of: "Klaus"))
        #expect(signAt.lowerBound < klausAt.lowerBound)
    }
}
