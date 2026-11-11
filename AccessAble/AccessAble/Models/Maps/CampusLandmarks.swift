import Foundation

/// A named campus building from OpenStreetMap, with the other names people use for it and its mapped entrances.
struct CampusBuilding: Equatable, Sendable {
    var name: String
    /// Nicknames and official names, such as "CULC" for Clough.
    var aliases: [String]
    /// Outer rings. Most buildings have one; a building drawn in parts has several.
    var outlines: [[GeoCoordinate]]
    var entrances: [CampusEntrance]

    var allNames: [String] { [name] + aliases }

    /// Ray casting on latitude and longitude, which is fine at building scale.
    func contains(_ point: GeoCoordinate) -> Bool {
        outlines.contains { ring in
            var inside = false
            var previous = ring.last
            for vertex in ring {
                if let previous, (vertex.latitude > point.latitude) != (previous.latitude > point.latitude) {
                    let crossing = previous.longitude + (point.latitude - previous.latitude)
                        / (vertex.latitude - previous.latitude) * (vertex.longitude - previous.longitude)
                    if point.longitude < crossing { inside.toggle() }
                }
                previous = vertex
            }
            return inside
        }
    }
}

struct CampusEntrance: Equatable, Sendable {
    var coordinate: GeoCoordinate
    /// OpenStreetMap's entrance tag: main, yes, service, exit, emergency...
    var kind: String
    /// yes, no, limited, or nil when nobody has mapped it.
    var wheelchair: String?
}

enum CampusLandmarks {
    /// Built by Scripts/CampusLandmarks/ExportCampusLandmarks.swift. Empty if the file is missing or unreadable.
    static let buildings: [CampusBuilding] = {
        guard let url = Bundle.main.url(forResource: "campus-landmarks", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return [] }
        return (try? decode(data)) ?? []
    }()

    static func decode(_ data: Data) throws -> [CampusBuilding] {
        try JSONDecoder().decode(Export.self, from: data).buildings.map { building in
            CampusBuilding(
                name: building.name,
                aliases: building.aliases,
                outlines: building.outlines.map { ring in
                    ring.compactMap { $0.count == 2 ? GeoCoordinate(latitude: $0[0], longitude: $0[1]) : nil }
                },
                entrances: building.entrances.map {
                    CampusEntrance(coordinate: GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude),
                                   kind: $0.kind, wheelchair: $0.wheelchair)
                }
            )
        }
    }

    private struct Export: Decodable {
        let buildings: [Building]
    }

    private struct Building: Decodable {
        let name: String
        let aliases: [String]
        /// [latitude, longitude] pairs.
        let outlines: [[[Double]]]
        let entrances: [Entrance]
    }

    private struct Entrance: Decodable {
        let latitude: Double
        let longitude: Double
        let kind: String
        let wheelchair: String?
    }
}
