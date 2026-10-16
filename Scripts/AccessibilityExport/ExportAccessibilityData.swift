import Foundation

// Set the name of the test area
let testAreaName = "Georgia Tech campus, Atlanta GA"

// The Overpass API is strict, so the edges are in this order: south, west, north, east
let southLat = 33.7700   // bottom edge of the box
let westLon = -84.4080   // left edge of the box
let northLat = 33.7820   // top edge of the box
let eastLon = -84.3880   // right edge of the box

if southLat >= northLat {
    print("Problem: southLat should be smaller than northLat")
    exit(1)
}
if westLon >= eastLon {
    print("Problem: westLon should be smaller than eastLon")
    exit(1)
}

let centerLat = (southLat + northLat) / 2
let centerLon = (westLon + eastLon) / 2

let heightKm = (northLat - southLat) * 111.0
let widthKm = (eastLon - westLon) * 111.0 * cos(centerLat * Double.pi / 180)

print("Test area: \(testAreaName)")
print("South: \(southLat)  West: \(westLon)  North: \(northLat)  East: \(eastLon)")
print("Center: \(centerLat), \(centerLon)")
print("Size: about \(String(format: "%.1f", widthKm)) km wide by \(String(format: "%.1f", heightKm)) km tall")
print("See it on a map: https://www.openstreetmap.org/?minlon=\(westLon)&minlat=\(southLat)&maxlon=\(eastLon)&maxlat=\(northLat)&box=yes")

// Step 2: Overpass query

func makeQuery() -> String {
    let box = "\(southLat),\(westLon),\(northLat),\(eastLon)"

    // Overpass query returning JSON format
    let query = """
    [out:json][timeout:60];
    (
      // Crossings: points tagged highway=crossing, and lines tagged footway=crossing
      node["highway"="crossing"](\(box));
      way["footway"="crossing"](\(box));
      // Audible signals: any node that has the traffic_signals:sound tag
      node["traffic_signals:sound"](\(box));
      // Vibrating crossing buttons
      node["traffic_signals:vibration"](\(box));
      // Tactile paving: any node or way that has the tactile_paving tag
      node["tactile_paving"](\(box));
      way["tactile_paving"](\(box));
      // Curbs: nodes tagged barrier=kerb, lines tagged barrier=kerb, or any node with a kerb tag
      node["barrier"="kerb"](\(box));
      way["barrier"="kerb"](\(box));
      node["kerb"](\(box));
      // Elevators: nodes tagged highway=elevator
      node["highway"="elevator"](\(box));
      // Entrances: any node with the entrance tag
      node["entrance"](\(box));
    );
    out center;
    """
    return query
}

let query = makeQuery()
print("")
print("Overpass query:")
print(query)

// Step 3: Count feature types and document coverage gaps

let outputFolder = "Data/AccessibilityExport"
let overpassURL = "https://overpass-api.de/api/interpreter"
let allFeatureTypes = ["crossing", "audible_signal", "vibrating_signal", "tactile_paving", "curb", "elevator", "entrance"]

struct OverpassResponse: Codable {
    let elements: [OverpassElement]
}

struct OverpassElement: Codable {
    let type: String
    let id: Int
    let lat: Double?
    let lon: Double?
    let center: OverpassCenter?
    let tags: [String: String]?
}

struct OverpassCenter: Codable {
    let lat: Double
    let lon: Double
}

// A tag set to "no" means the feature is absent, so it isn't counted as present.
func isPresent(_ tags: [String: String], _ key: String) -> Bool {
    guard let value = tags[key] else { return false }
    return value != "no"
}

func findFeatureTypes(tags: [String: String]) -> [String] {
    var types: [String] = []

    if tags["highway"] == "crossing" || tags["footway"] == "crossing" {
        types.append("crossing")
    }
    if isPresent(tags, "traffic_signals:sound") {
        types.append("audible_signal")
    }
    if isPresent(tags, "traffic_signals:vibration") {
        types.append("vibrating_signal")
    }
    if isPresent(tags, "tactile_paving") {
        types.append("tactile_paving")
    }
    if tags["barrier"] == "kerb" || isPresent(tags, "kerb") {
        types.append("curb")
    }
    if tags["highway"] == "elevator" {
        types.append("elevator")
    }
    if isPresent(tags, "entrance") {
        types.append("entrance")
    }

    return types
}

func fetchFromOverpass(query: String) async -> Data? {
    guard let url = URL(string: overpassURL) else {
        print("The Overpass URL is not valid")
        return nil
    }
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 90
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("AccessAble-student-project", forHTTPHeaderField: "User-Agent")

    let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    request.httpBody = "data=\(encodedQuery)".data(using: .utf8)

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            print("Overpass gave status code \(httpResponse.statusCode). Try again in a minute.")
            return nil
        }
        return data
    } catch {
        print("The request failed: \(error)")
        return nil
    }
}

func decodeResponse(data: Data) -> OverpassResponse? {
    do {
        let decoder = JSONDecoder()
        return try decoder.decode(OverpassResponse.self, from: data)
    } catch {
        print("Could not read the Overpass JSON: \(error)")
        return nil
    }
}

func countType(elements: [OverpassElement], type: String) -> Int {
    var count = 0
    for element in elements {
        let tags = element.tags ?? [:]
        if findFeatureTypes(tags: tags).contains(type) {
            count += 1
        }
    }
    return count
}

func countTypeWithTag(elements: [OverpassElement], type: String, tag: String) -> Int {
    var count = 0
    for element in elements {
        let tags = element.tags ?? [:]
        if findFeatureTypes(tags: tags).contains(type) && tags[tag] != nil {
            count += 1
        }
    }
    return count
}

func percent(part: Int, whole: Int) -> String {
    if whole == 0 { return "n/a" }
    let value = Double(part) / Double(whole) * 100
    return String(format: "%.0f%%", value)
}

func makeSummary(elements: [OverpassElement]) -> String {
    var text = "# Accessibility Data Coverage Summary\n\n"
    text += "- Test area: \(testAreaName)\n"
    text += "- Bounding box (south, west, north, east): \(southLat), \(westLon), \(northLat), \(eastLon)\n"
    text += "- Source: OpenStreetMap via the Overpass API, fetched \(Date().formatted(date: .abbreviated, time: .omitted))\n"
    text += "- Total elements found: \(elements.count)\n\n"

    text += "## Feature counts\n\n| Feature type | Count |\n|---|---|\n"
    var emptyTypes: [String] = []
    for type in allFeatureTypes {
        let count = countType(elements: elements, type: type)
        text += "| \(type) | \(count) |\n"
        if count == 0 { emptyTypes.append(type) }
    }
    
    text += "\n## Coverage gaps\n\n"
    let gapChecks = [
        ("crossing", "tactile_paving"),
        ("crossing", "kerb"),
        ("entrance", "wheelchair"),
        ("elevator", "wheelchair")
    ]
    for (type, tag) in gapChecks {
        let total = countType(elements: elements, type: type)
        let withTag = countTypeWithTag(elements: elements, type: type, tag: tag)
        text += "- \(type)s with a \(tag) tag: \(withTag) of \(total) (\(percent(part: withTag, whole: total)))\n"
    }

    var signalCrossings = 0
    var signalCrossingsWithSound = 0
    for element in elements {
        let tags = element.tags ?? [:]
        let isSignalized = tags["crossing"] == "traffic_signals" || tags["crossing:signals"] == "yes"
        if findFeatureTypes(tags: tags).contains("crossing") && isSignalized {
            signalCrossings += 1
            if tags["traffic_signals:sound"] != nil || tags["traffic_signals:vibration"] != nil {
                signalCrossingsWithSound += 1
            }
        }
    }
    text += "- Signalized crossings with sound/vibration tags: \(signalCrossingsWithSound) of \(signalCrossings) (\(percent(part: signalCrossingsWithSound, whole: signalCrossings)))\n"

    text += "\n## Feature types with nothing found\n\n"
    if emptyTypes.isEmpty {
        text += "- None, every feature type has at least one feature\n"
    }
    for type in emptyTypes {
        text += "- \(type): no features found in the test area\n"
    }

    text += "\n## Notes\n\n"
    text += "- A missing tag means nobody has mapped it yet. It does NOT mean the feature is not accessible.\n"
    text += "- Lines (ways) are counted as one feature each. A crossing mapped as both a road node and a footway line is counted twice.\n"
    text += "- Curb details are usually on separate kerb nodes at each end of a crossing, so few crossings carry a kerb tag themselves.\n"
    text += "- Feature counts skip tags set to \"no\"; the coverage gaps count any tag, including \"no\".\n"

    return text
}

// Step 4: Export element type, ID, coordinates or relevant geometry, and original tags

// Data structures for JSON export
struct ExportFile: Codable {
    let testArea: String
    let boundingBox: [String: Double]
    let featureCount: Int
    let features: [ExportedFeature]
}

struct ExportedFeature: Codable {
    let osmType: String
    let osmId: Int
    let featureTypes: [String]
    let latitude: Double?
    let longitude: Double?
    let tags: [String: String]
}

func convertElements(elements: [OverpassElement]) -> [ExportedFeature] {
    var exported: [ExportedFeature] = []

    for element in elements {
        let tags = element.tags ?? [:]
        let types = findFeatureTypes(tags: tags)
        if types.isEmpty { continue }

        // Ways have no lat/lon of their own, so use their center point
        var latitude = element.lat
        var longitude = element.lon
        if let center = element.center {
            latitude = center.lat
            longitude = center.lon
        }

        exported.append(ExportedFeature(
            osmType: element.type,
            osmId: element.id,
            featureTypes: types,
            latitude: latitude,
            longitude: longitude,
            tags: tags
        ))
    }

    return exported
}

print("")
print("Asking Overpass for the data (this can take a bit)...")

// If either step fails, the functions already printed the reason
guard let data = await fetchFromOverpass(query: query),
      let response = decodeResponse(data: data) else {
    exit(1)
}
print("Overpass sent back \(response.elements.count) elements")

let summary = makeSummary(elements: response.elements)
print("")
print(summary)

let features = convertElements(elements: response.elements)
print("Converted \(features.count) features")

let exportFile = ExportFile(
    testArea: testAreaName,
    boundingBox: ["south": southLat, "west": westLon, "north": northLat, "east": eastLon],
    featureCount: features.count,
    features: features
)

do {
    try FileManager.default.createDirectory(atPath: outputFolder, withIntermediateDirectories: true)

    try summary.write(toFile: "\(outputFolder)/coverage_summary.md", atomically: true, encoding: .utf8)
    print("Saved the summary in \(outputFolder)/coverage_summary.md")

    // sortedKeys keeps the key order stable so git diffs stay small
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let exportData = try encoder.encode(exportFile)
    try exportData.write(to: URL(fileURLWithPath: "\(outputFolder)/accessibility_export.json"))
    print("Saved the export in \(outputFolder)/accessibility_export.json")
} catch {
    print("Could not save the files: \(error)")
    exit(1)
}

