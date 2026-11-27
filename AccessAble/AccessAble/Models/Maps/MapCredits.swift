import Foundation

/// Owner: Maps. The attributions the map data licences ask for, listed on the Credits screen.
struct MapCredit: Identifiable {
    let id: String
    let heading: String
    let text: String
    let linkTitle: String
    let url: URL
}

enum MapCredits {
    static let openStreetMapCopyright = URL(string: "https://www.openstreetmap.org/copyright")!
    static let stadiaMaps = URL(string: "https://stadiamaps.com/")!
    static let appleMapsLegal = URL(string: "https://www.apple.com/legal/internet-services/maps/")!

    static let all = [
        MapCredit(
            id: "openstreetmap",
            heading: "Map data",
            text: "© OpenStreetMap contributors. Walking paths, crossings, curbs and entrances come from OpenStreetMap, "
                + "which is available under the Open Database License (ODbL).",
            linkTitle: "OpenStreetMap copyright and licence",
            url: openStreetMapCopyright
        ),
        MapCredit(
            id: "stadia",
            heading: "Routing",
            text: "Walking routes are calculated by the open-source Valhalla engine, hosted by Stadia Maps, "
                + "using OpenStreetMap data.",
            linkTitle: "Stadia Maps",
            url: stadiaMaps
        ),
        MapCredit(
            id: "apple",
            heading: "Maps",
            text: "Map imagery and maps are provided by Apple Maps.",
            linkTitle: "Apple Maps legal notices",
            url: appleMapsLegal
        ),
    ]
}
