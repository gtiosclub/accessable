import Foundation
import Testing
@testable import AccessAble

@MainActor
struct NavigateCommandTests {
    private let clough = Destination(
        name: "Clough Undergraduate Learning Commons",
        coordinate: GeoCoordinate(latitude: 33.7749, longitude: -84.3964)
    )

    @Test
    func keywordParsesTakeMeToPhrases() async {
        let interpreter = KeywordCommandInterpreter()
        for phrase in [
            "take me to Clough",
            "navigate to Clough",
            "go to Clough",
            "directions to Clough",
        ] {
            #expect(await interpreter.interpret(phrase) == .navigate(to: "Clough"))
        }
    }

    @Test
    func keywordDoesNotTreatBareGoAsNavigate() async {
        let interpreter = KeywordCommandInterpreter()
        #expect(await interpreter.interpret("go") == .unknown("go"))
    }

    @Test
    func commandViewModelPushesOneMatch() async {
        var services = AppServices.preview
        services.commands = KeywordCommandInterpreter()
        let lookup = DestinationLookup(
            nicknames: FixedNicknames(places: [clough]),
            saved: FixedSaved(places: []),
            mapKit: FixedMapKit(places: [])
        )
        let viewModel = CommandViewModel(services: services, destinations: lookup)
        var opened: Destination?
        viewModel.onOpenDestination = { opened = $0 }

        await viewModel.run("take me to Clough")

        #expect(opened == clough)
    }

    @Test
    func commandViewModelSpeaksSeveral() async {
        let a = Destination(name: "Alpha Hall", coordinate: GeoCoordinate(latitude: 1, longitude: 1))
        let b = Destination(name: "Alpha Commons", coordinate: GeoCoordinate(latitude: 2, longitude: 2))
        var services = AppServices.preview
        services.commands = KeywordCommandInterpreter()
        let lookup = DestinationLookup(
            nicknames: FixedNicknames(places: [a, b]),
            saved: FixedSaved(places: []),
            mapKit: FixedMapKit(places: [])
        )
        let viewModel = CommandViewModel(services: services, destinations: lookup)

        await viewModel.run("take me to Alpha")

        #expect(viewModel.lastReply == "I found Alpha Hall and Alpha Commons. Say take me to one of those.")
    }

    @Test
    func commandViewModelSpeaksNone() async {
        var services = AppServices.preview
        services.commands = KeywordCommandInterpreter()
        let lookup = DestinationLookup(
            nicknames: FixedNicknames(places: []),
            saved: FixedSaved(places: []),
            mapKit: FixedMapKit(places: [])
        )
        let viewModel = CommandViewModel(services: services, destinations: lookup)

        await viewModel.run("take me to Nowhere")

        #expect(viewModel.lastReply == "I couldn't find Nowhere.")
    }
}

/// Shared with DestinationLookupTests naming — local copies for this file's isolation.
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
