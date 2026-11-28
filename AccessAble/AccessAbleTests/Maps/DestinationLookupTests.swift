import Foundation
import Testing
@testable import AccessAble

struct DestinationLookupTests {
    // Each source has its own "Clough", so which one comes back says which source won.
    private let nicknameClough = Destination.at("Clough Undergraduate Learning Commons", 33.7749, -84.3964)
    private let savedClough = Destination.at("Clough", 33.7750, -84.3965)
    private let mapKitClough = Destination.at("Clough Commons", 33.7751, -84.3966)

    @Test
    func nicknameBeatsSavedBeatsMapKit() async throws {
        let mapKit = FixedMapKit([DestinationCandidate(mapKitClough)])
        let result = try await DestinationLookup.fixed(
            nicknames: [DestinationCandidate(nicknameClough, names: [nicknameClough.name, "Clough"])],
            saved: [DestinationCandidate(savedClough)],
            mapKit: mapKit
        ).lookUp("Clough")
        #expect(result == .one(nicknameClough))
        #expect(mapKit.searches == 0)
    }

    @Test
    func savedBeatsMapKit() async throws {
        let mapKit = FixedMapKit([DestinationCandidate(mapKitClough)])
        let result = try await DestinationLookup.fixed(saved: [DestinationCandidate(savedClough)], mapKit: mapKit)
            .lookUp("Clough")
        #expect(result == .one(savedClough))
        #expect(mapKit.searches == 0)
    }

    @Test
    func mapKitWhenNoNicknameOrSaved() async throws {
        let result = try await DestinationLookup.fixed(
            nicknames: [DestinationCandidate(.at("Tech Tower"))],
            saved: [DestinationCandidate(.at("Home"))],
            mapKit: FixedMapKit([DestinationCandidate(mapKitClough)])
        ).lookUp("Clough")
        #expect(result == .one(mapKitClough))
    }

    @Test
    func anExactNameBeatsOtherMatches() async throws {
        let annex = Destination.at("Clough Commons Annex", 1, 1)
        let result = try await DestinationLookup.fixed(
            mapKit: FixedMapKit([DestinationCandidate(annex), DestinationCandidate(mapKitClough)])
        ).lookUp("clough commons")
        #expect(result == .one(mapKitClough))
    }

    @Test
    func anExactNameIgnoresAccentsAndPunctuation() async throws {
        let cafe = Destination.at("Café Señor", 1, 1)
        let result = try await DestinationLookup.fixed(
            nicknames: [DestinationCandidate(cafe), DestinationCandidate(.at("Cafe Senor Annex", 2, 2))]
        ).lookUp("cafe senor")
        #expect(result == .one(cafe))
    }

    @Test
    func aSavedLabelCountsAsItsName() async throws {
        let home = Destination.at("12 Main Street", 1, 1)
        let result = try await DestinationLookup.fixed(
            saved: [DestinationCandidate(home, names: ["Home", home.name]), DestinationCandidate(.at("Home Depot", 2, 2))]
        ).lookUp("Home")
        #expect(result == .one(home))
    }

    @Test
    func severalPutsExactThenPrefixThenOtherAndKeepsThree() async throws {
        let other = Destination.at("West Alpha Hall", 1, 1)
        let prefix = Destination.at("Alpha Commons", 2, 2)
        let exactA = Destination.at("Alpha", 3, 3)
        let exactB = Destination.at("Alpha", 4, 4)
        let result = try await DestinationLookup.fixed(nicknames: [other, prefix, exactA, exactB].map {
            DestinationCandidate($0)
        }).lookUp("Alpha")
        #expect(result == .several([exactA, exactB, prefix]))
    }

    @Test
    func noneWhenNothingMatches() async throws {
        let result = try await DestinationLookup.fixed(mapKit: FixedMapKit([DestinationCandidate(mapKitClough)]))
            .lookUp("Nowhere")
        #expect(result == .none)
    }

    @Test
    func aSearchThatCouldNotRunIsNotNone() async {
        let lookup = DestinationLookup.fixed(mapKit: FixedMapKit(error: PlaceLookupError.offline))
        await #expect(throws: PlaceLookupError.offline) { try await lookup.lookUp("Clough") }
    }

    @Test
    func homeIsTheSavedPlaceLabelledHome() async {
        let home = Destination.at("12 Main Street", 1, 1)
        let lookup = DestinationLookup.fixed(saved: [
            DestinationCandidate(.at("Home Depot", 2, 2)),
            DestinationCandidate(home, names: ["Home", home.name]),
        ])
        #expect(await lookup.home() == home)
        #expect(await DestinationLookup.fixed(saved: [DestinationCandidate(.at("Home Depot"))]).home() == nil)
    }
}
