import Foundation
import Testing
@testable import AccessAble

private struct FixedNicknames: NicknameDestinationSource {
    var places: [Destination]
    func destinations(matching query: String) -> [Destination] {
        places.filter { $0.name.localizedStandardContains(query) }
    }
}

private struct FixedSaved: SavedDestinationSource {
    var places: [Destination]
    func destinations(matching query: String) async -> [Destination] {
        places.filter { $0.name.localizedStandardContains(query) }
    }
}

private struct FixedMapKit: MapDestinationSource {
    var places: [Destination]
    func destinations(matching query: String) async -> [Destination] {
        places.filter { $0.name.localizedStandardContains(query) }
    }
}

struct DestinationLookupTests {
    private let clough = Destination(
        name: "Clough Undergraduate Learning Commons",
        coordinate: GeoCoordinate(latitude: 33.7749, longitude: -84.3964)
    )
    private let savedHome = Destination(
        name: "Home",
        coordinate: GeoCoordinate(latitude: 33.78, longitude: -84.40)
    )
    private let willis = Destination(
        name: "Willis Tower",
        coordinate: GeoCoordinate(latitude: 41.8789, longitude: -87.6359)
    )
    private let other = Destination(
        name: "Other Tower",
        coordinate: GeoCoordinate(latitude: 41.88, longitude: -87.64)
    )

    private func lookup(
        nicknames: [Destination] = [],
        saved: [Destination] = [],
        mapKit: [Destination] = []
    ) -> DestinationLookup {
        DestinationLookup(
            nicknames: FixedNicknames(places: nicknames),
            saved: FixedSaved(places: saved),
            mapKit: FixedMapKit(places: mapKit)
        )
    }

    @Test
    func nicknameBeatsSavedBeatsMapKit() async {
        let result = await lookup(
            nicknames: [clough],
            saved: [savedHome],
            mapKit: [willis]
        ).lookUp("Clough")
        #expect(result == .one(clough))
    }

    @Test
    func savedUsedWhenNoNickname() async {
        let result = await lookup(saved: [savedHome], mapKit: [willis]).lookUp("Home")
        #expect(result == .one(savedHome))
    }

    @Test
    func mapKitUsedWhenNoNicknameOrSaved() async {
        let result = await lookup(mapKit: [willis]).lookUp("Willis")
        #expect(result == .one(willis))
    }

    @Test
    func severalReturnsTopThree() async {
        let a = Destination(name: "Alpha Hall", coordinate: GeoCoordinate(latitude: 1, longitude: 1))
        let b = Destination(name: "Alpha Commons", coordinate: GeoCoordinate(latitude: 2, longitude: 2))
        let c = Destination(name: "Alpha Center", coordinate: GeoCoordinate(latitude: 3, longitude: 3))
        let d = Destination(name: "Alpha Annex", coordinate: GeoCoordinate(latitude: 4, longitude: 4))
        let result = await lookup(nicknames: [a, b, c, d]).lookUp("Alpha")
        #expect(result == .several([a, b, c]))
    }

    @Test
    func noneWhenNothingMatches() async {
        let result = await lookup(mapKit: [willis]).lookUp("Nowhere")
        #expect(result == .none)
    }
}
