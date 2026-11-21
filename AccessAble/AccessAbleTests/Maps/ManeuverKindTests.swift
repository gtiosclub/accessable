import Foundation
import Testing
@testable import AccessAble

struct ManeuverKindTests {
    @Test(arguments: [ManeuverKind.stairs, .elevator, .escalator, .enterBuilding, .exitBuilding])
    func levelChangesAndBuildingEntrancesNeedAttention(_ kind: ManeuverKind) {
        #expect(kind.haptic == .attention)
    }

    @Test
    func newKindsSurviveACodableRoundTrip() throws {
        let kinds: [ManeuverKind] = [.stairs, .elevator, .escalator, .enterBuilding, .exitBuilding]
        let data = try JSONEncoder().encode(kinds)
        #expect(String(decoding: data, as: UTF8.self)
            == #"["stairs","elevator","escalator","enterBuilding","exitBuilding"]"#)
        #expect(try JSONDecoder().decode([ManeuverKind].self, from: data) == kinds)
    }

    @Test
    func decodesPayloadsSavedBeforeTheNewKinds() throws {
        let json = #"["depart","straight","turnLeft","turnRight","slightLeft","slightRight","uTurn","cross","arrive"]"#
        let kinds = try JSONDecoder().decode([ManeuverKind].self, from: Data(json.utf8))
        #expect(kinds == [.depart, .straight, .turnLeft, .turnRight, .slightLeft, .slightRight, .uTurn, .cross,
                          .arrive])
    }
}
