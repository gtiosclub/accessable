import Foundation
import Testing
@testable import AccessAble

struct ValhallaManeuverDecoderTests {
    private func fixture() throws -> Data {
        let url = try #require(Bundle.main.url(forResource: "valhalla-route-sample", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    @Test
    func associatesSavedManeuversWithShapeVertices() throws {
        let legs = try ValhallaGeometryDecoder.decodeLegsWithManeuvers(from: fixture())
        #expect(legs.count == 1)
        let leg = try #require(legs.first)
        #expect(leg.coordinates.count == 35)
        #expect(leg.steps.map(\.coordinateIndex) == [0, 3, 5, 6, 11, 26, 32, 33, 34])
        #expect(leg.steps.map(\.kind) == [
            .depart, .slightRight, .turnRight, .straight, .slightLeft,
            .straight, .turnRight, .turnLeft, .arrive
        ])
        let arrival = try #require(leg.steps.last)
        #expect(leg.coordinates[arrival.coordinateIndex] == leg.coordinates.last)
    }

    @Test
    func unnamedWalkwaysKeepTheDepartureAndJoinedTurn() throws {
        let steps = try ValhallaGeometryDecoder.decodeLegsWithManeuvers(from: fixture())[0].steps
        #expect(steps[0].instruction == "Walk south.")
        #expect(steps[0].spokenInstruction == "Walk south. Then keep right.")
        #expect(steps[0].announcesNextStep)
        #expect(steps[2].spokenInstruction == "Turn right. Then continue.")
        #expect(steps[5].spokenInstruction == "Continue.")
    }

    @Test(arguments: [
        ("Walk east on the walkway for 50 meters.", "Walk east for 50 meters."),
        ("Continue on Skiles Walkway.", "Continue on Skiles Walkway."),
        ("Turn right onto the walkway by Tech Green.", "Turn right onto the walkway by Tech Green."),
        ("Cross the walkway at Ferst Drive.", "Cross the walkway at Ferst Drive."),
        ("Take the stairs down to the walkway.", "Take the stairs down to the walkway."),
        ("Take the elevator to the walkway.", "Take the elevator to the walkway."),
        ("Turn left onto the walkway. Then Cross Ferst Drive.", "Turn left. Then cross Ferst Drive."),
    ])
    func keepsNamesDistancesAndSafetyCues(_ input: String, _ spoken: String) throws {
        let data = try alteredFixture { $0[1]["verbal_pre_transition_instruction"] = input }
        let steps = try ValhallaGeometryDecoder.decodeLegsWithManeuvers(from: data)[0].steps
        #expect(steps[1].spokenInstruction == spoken)
    }

    @Test
    func marksStepsWhoseSpeechAnnouncesTheNextStep() throws {
        let legs = try ValhallaGeometryDecoder.decodeLegsWithManeuvers(from: fixture())
        let flagged = legs[0].steps.indices.filter { legs[0].steps[$0].announcesNextStep }
        #expect(flagged == [0, 2])
    }

    private func alteredFixture(_ edit: (inout [[String: Any]]) -> Void) throws -> Data {
        var response = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        var trip = try #require(response["trip"] as? [String: Any])
        var legs = try #require(trip["legs"] as? [[String: Any]])
        var maneuvers = try #require(legs[0]["maneuvers"] as? [[String: Any]])
        edit(&maneuvers)
        legs[0]["maneuvers"] = maneuvers
        trip["legs"] = legs
        response["trip"] = trip
        return try JSONSerialization.data(withJSONObject: response)
    }

    @Test(arguments: [-1, 35])
    func rejectsInvalidPosition(_ index: Int) throws {
        let data = try alteredFixture { $0[0]["begin_shape_index"] = index }
        #expect(throws: ValhallaGeometryDecoder.DecodeError.invalidManeuverIndex) {
            try ValhallaGeometryDecoder.decodeLegsWithManeuvers(from: data)
        }
    }

    @Test
    func rejectsOutOfOrderManeuvers() throws {
        let data = try alteredFixture { $0.swapAt(1, 2) }
        #expect(throws: ValhallaGeometryDecoder.DecodeError.maneuversOutOfOrder) {
            try ValhallaGeometryDecoder.decodeLegsWithManeuvers(from: data)
        }
    }

    @Test
    func fallsBackToWrittenInstruction() throws {
        let data = try alteredFixture { $0[0].removeValue(forKey: "verbal_pre_transition_instruction") }
        let legs = try ValhallaGeometryDecoder.decodeLegsWithManeuvers(from: data)
        #expect(legs[0].steps[0].spokenInstruction == "Walk south.")
    }

    @Test
    func rejectsUnknownType() throws {
        let data = try alteredFixture { $0[0]["type"] = 999 }
        #expect(throws: ValhallaGeometryDecoder.DecodeError.unsupportedManeuverType(999)) {
            try ValhallaGeometryDecoder.decodeLegsWithManeuvers(from: data)
        }
    }
    
    @Test
    func decodesLevelChangesAndBuildingEntrances() throws {
        let data = try alteredFixture { maneuvers in
            for (index, type) in zip(1..., [39, 40, 41, 42, 43]) { maneuvers[index]["type"] = type }
        }
        let legs = try ValhallaGeometryDecoder.decodeLegsWithManeuvers(from: data)
        #expect(legs[0].steps[1...5].map(\.kind) == [.elevator, .stairs, .escalator, .enterBuilding, .exitBuilding])
    }

    @Test(arguments: [25, 26, 27])
    func mapsMergesAndRoundaboutsToStraight(_ type: Int) throws {
        let data = try alteredFixture { $0[1]["type"] = type }
        let legs = try ValhallaGeometryDecoder.decodeLegsWithManeuvers(from: data)
        #expect(legs[0].steps[1].kind == .straight)
    }
}
