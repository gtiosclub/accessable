import Foundation

/// Owner: Maps. The attributions the map data licences ask for, listed on the Credits screen.
struct MapCredit: Identifiable, Equatable {
    let id: String
    let heading: String
    let text: String
    let linkTitle: String
    let linkAccessibilityLabel: String
    let url: URL
}

enum MapCredits {
    static let openStreetMapCopyright = URL(string: "https://www.openstreetmap.org/copyright")!
    static let stadiaMaps = URL(string: "https://stadiamaps.com/")!
    static let valhalla = URL(string: "https://valhalla.github.io/valhalla/")!
    static let appleMapsLegal = URL(string: "https://www.apple.com/legal/internet-services/maps/")!

    static let all = [
        MapCredit(
            id: "openstreetmap",
            heading: "Map data",
            text: "© OpenStreetMap contributors. Walking paths, crossings, curbs and entrances come from OpenStreetMap, "
                + "which is available under the Open Database License (ODbL).",
            linkTitle: "OpenStreetMap copyright and licence",
            linkAccessibilityLabel: "OpenStreetMap copyright and licence, opens in Safari",
            url: openStreetMapCopyright
        ),
        MapCredit(
            id: "stadia",
            heading: "Routing",
            text: "Walking routes are calculated by Valhalla, hosted by Stadia Maps, using OpenStreetMap data.",
            linkTitle: "Stadia Maps",
            linkAccessibilityLabel: "Stadia Maps, opens in Safari",
            url: stadiaMaps
        ),
        MapCredit(
            id: "valhalla",
            heading: "Routing engine",
            text: "Valhalla is open-source routing software.",
            linkTitle: "Valhalla",
            linkAccessibilityLabel: "Valhalla routing engine, opens in Safari",
            url: valhalla
        ),
        MapCredit(
            id: "apple",
            heading: "Maps",
            text: "Maps by Apple Maps.",
            linkTitle: "Apple Maps legal notices",
            linkAccessibilityLabel: "Apple Maps legal notices, opens in Safari",
            url: appleMapsLegal
        ),
    ]
}
