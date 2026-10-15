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
        #expect(leg.steps.first?.instruction == "Walk south on the walkway.")
        let arrival = try #require(leg.steps.last)
        #expect(leg.coordinates[arrival.coordinateIndex] == leg.coordinates.last)
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
        #expect(legs[0].steps[0].spokenInstruction == legs[0].steps[0].instruction)
    }

    @Test
    func rejectsUnknownType() throws {
        let data = try alteredFixture { $0[0]["type"] = 999 }
        #expect(throws: ValhallaGeometryDecoder.DecodeError.unsupportedManeuverType(999)) {
            try ValhallaGeometryDecoder.decodeLegsWithManeuvers(from: data)
        }
    }
    
    @Test(arguments: [39, 40, 41, 42, 43])
    func keepsPedestrianManeuvers(_ type: Int) throws {
        let data = try alteredFixture { $0[1]["type"] = type }
        let legs = try ValhallaGeometryDecoder.decodeLegsWithManeuvers(from: data)
        #expect(legs[0].steps[1].kind == .straight)
    }
}
