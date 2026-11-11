import Foundation

// Exports the named buildings on the Georgia Tech campus, with their nicknames, outlines and entrances, from
// OpenStreetMap. The app bundles the result, so trips can match signs to buildings along the route (LAND-2).
// Run from the repository root: swift Scripts/CampusLandmarks/ExportCampusLandmarks.swift

// Same box as Scripts/AccessibilityExport, in Overpass order: south, west, north, east
let southLat = 33.7700
let westLon = -84.4080
let northLat = 33.7820
let eastLon = -84.3880

let overpassURL = URL(string: "https://overpass-api.de/api/interpreter")!
let outputPath = "AccessAble/AccessAble/Resources/Maps/campus-landmarks.json"
// Tags that hold other names people use for a building. Values can hold several names separated by ";".
let aliasTags = ["short_name", "loc_name", "alt_name", "official_name", "old_name"]

let box = "\(southLat),\(westLon),\(northLat),\(eastLon)"
let query = """
[out:json][timeout:120];
(
  way["building"]["name"](\(box));
  relation["building"]["name"](\(box));
)->.buildings;
.buildings out body geom qt;
(
  node(w.buildings)["entrance"];
  way(r.buildings)->.parts;
  node(w.parts)["entrance"];
);
out body qt;
"""

struct OverpassResponse: Decodable {
    let elements: [Element]
}

struct Element: Decodable {
    let type: String
    let id: Int
    let lat: Double?
    let lon: Double?
    let tags: [String: String]?
    /// Way outline.
    let geometry: [Point]?
    /// Relation parts; only outer rings are kept.
    let members: [Member]?
}

struct Member: Decodable {
    let type: String
    let role: String
    let geometry: [Point]?
}

struct Point: Codable, Hashable {
    let lat: Double
    let lon: Double
}

struct Export: Encodable {
    let source = "OpenStreetMap contributors, through the Overpass API"
    let license = "ODbL (https://www.openstreetmap.org/copyright)"
    let exportDate: String
    let boundingBox: [Double]
    let buildings: [Building]
}

struct Building: Encodable {
    let osmType: String
    let osmId: Int
    let name: String
    let aliases: [String]
    /// Outer rings as [latitude, longitude] pairs.
    let outlines: [[[Double]]]
    let entrances: [Entrance]
}

struct Entrance: Encodable {
    let latitude: Double
    let longitude: Double
    /// The entrance tag: main, yes, service, exit, emergency...
    let kind: String
    let wheelchair: String?
    let automaticDoor: String?
}

// 7 decimals is about 1 cm, and keeps the file small
func rounded(_ value: Double) -> Double {
    (value * 10_000_000).rounded() / 10_000_000
}

print("Querying Overpass for named buildings in \(box)…")
var request = URLRequest(url: overpassURL)
request.httpMethod = "POST"
request.setValue("AccessAble-GTiOSClub/1.0 (campus landmark export)", forHTTPHeaderField: "User-Agent")
request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")".data(using: .utf8)
var data = Data()
var status = 0
// the public server answers 429, 503 or 504 when busy; it asks clients to back off and retry
for wait in [0, 15, 30, 60] {
    if wait > 0 {
        print("Overpass is busy (\(status)); retrying in \(wait) s")
        try await Task.sleep(for: .seconds(wait))
    }
    let (body, response) = try await URLSession.shared.data(for: request)
    data = body
    status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if ![429, 503, 504].contains(status) { break }
}
guard status == 200 else {
    print("Problem: Overpass answered \(status)")
    print(String(decoding: data.prefix(500), as: UTF8.self))
    exit(1)
}
let elements = try JSONDecoder().decode(OverpassResponse.self, from: data).elements

/// A relation's outer ring is often split across several ways that meet end to end; this joins them back into
/// closed rings. A piece that can't be closed is closed by its first point, so it still reads as an outline.
func closedRings(_ pieces: [[Point]]) -> [[Point]] {
    var pieces = pieces.filter { $0.count >= 2 }
    var rings: [[Point]] = []
    while !pieces.isEmpty {
        var ring = pieces.removeFirst()
        while ring.first != ring.last {
            guard let index = pieces.firstIndex(where: { $0.first == ring.last || $0.last == ring.last }) else { break }
            let piece = pieces.remove(at: index)
            ring += (piece.first == ring.last ? piece : piece.reversed()).dropFirst()
        }
        if ring.first != ring.last, let first = ring.first { ring.append(first) }
        if ring.count >= 4 { rings.append(ring) }
    }
    return rings
}

// Entrance nodes sit on building outlines, so an entrance belongs to the building with that exact vertex
var entrancesByPoint: [Point: Element] = [:]
for element in elements where element.type == "node" {
    if let lat = element.lat, let lon = element.lon { entrancesByPoint[Point(lat: lat, lon: lon)] = element }
}

var buildings: [Building] = []
for element in elements where element.type == "way" || element.type == "relation" {
    guard let tags = element.tags, let name = tags["name"] else { continue }
    let rings: [[Point]] = element.type == "way"
        ? [element.geometry ?? []]
        : closedRings((element.members ?? []).filter { $0.type == "way" && $0.role == "outer" }.compactMap(\.geometry))
    guard !rings.joined().isEmpty else { continue }

    var aliases: [String] = []
    for tag in aliasTags {
        for alias in (tags[tag] ?? "").split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) })
        where !alias.isEmpty && alias != name && !aliases.contains(alias) {
            aliases.append(alias)
        }
    }

    var seen = Set<Point>()
    let entrances = rings.joined().compactMap { point -> Entrance? in
        guard let node = entrancesByPoint[point], seen.insert(point).inserted else { return nil }
        return Entrance(latitude: rounded(point.lat), longitude: rounded(point.lon),
                        kind: node.tags?["entrance"] ?? "yes", wheelchair: node.tags?["wheelchair"],
                        automaticDoor: node.tags?["automatic_door"])
    }

    buildings.append(Building(
        osmType: element.type, osmId: element.id, name: name, aliases: aliases,
        outlines: rings.map { $0.map { [rounded($0.lat), rounded($0.lon)] } },
        entrances: entrances
    ))
}
buildings.sort { $0.name < $1.name }

let export = Export(
    exportDate: ISO8601DateFormatter().string(from: .now),
    boundingBox: [southLat, westLon, northLat, eastLon],
    buildings: buildings
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try FileManager.default.createDirectory(
    at: URL(fileURLWithPath: outputPath).deletingLastPathComponent(), withIntermediateDirectories: true
)
try encoder.encode(export).write(to: URL(fileURLWithPath: outputPath))

let withEntrances = buildings.filter { !$0.entrances.isEmpty }.count
let withAliases = buildings.filter { !$0.aliases.isEmpty }.count
print("Wrote \(outputPath)")
print("\(buildings.count) named buildings, \(withAliases) with nicknames, \(withEntrances) with mapped entrances")
print("\(buildings.reduce(0) { $0 + $1.entrances.count }) entrances")
