// ExportAccessibilityData.swift.
// M5 - ACCESS-1: Audit and export OSM accessibility features.
// Step 1: define the test area.

import Foundation

// Set the name of the test area
let testAreaName = "Georgia Tech campus, Atlanta GA"

// The test area is a rectangle.
// The Overpass API is strict, so the edges are in this order: south, west, north, east
let southLat = 33.7700   // bottom edge of the box
let westLon = -84.4080   // left edge of the box
let northLat = 33.7820   // top edge of the box
let eastLon = -84.3880   // right edge of the box

// These are just safety checks.
// I'm making sure that the box even makes sense.
if southLat >= northLat {
    print("Problem: southLat should be smaller than northLat")
    exit(1)
}
if westLon >= eastLon {
    print("Problem: westLon should be smaller than eastLon")
    exit(1)
}

// I'm finding the center so we can look at it on a map
let centerLat = (southLat + northLat) / 2
let centerLon = (westLon + eastLon) / 2

// I'm figuring out how big the box is.
// You multiply by 111 since 1 latitude degree is about 111km.
// Longitude gets shorter as you move away from the equator, so we
// multiply by the cosine of the latitude.
let heightKm = (northLat - southLat) * 111.0
let widthKm = (eastLon - westLon) * 111.0 * cos(centerLat * Double.pi / 180)

// Printing the values so I can check them
print("Test area: \(testAreaName)")
print("South: \(southLat)  West: \(westLon)  North: \(northLat)  East: \(eastLon)")
print("Center: \(centerLat), \(centerLon)")
print("Size: about \(String(format: "%.1f", widthKm)) km wide by \(String(format: "%.1f", heightKm)) km tall")
print("See it on a map: https://www.openstreetmap.org/?minlon=\(westLon)&minlat=\(southLat)&maxlon=\(eastLon)&maxlat=\(northLat)&box=yes")


// Step 2: Overpass query

// Builds the text of the Overpass query.
// Overpass is the tool that lets us ask OpenStreetMap for specific features.
func makeQuery() -> String {
    // Overpass needs the box in this format: south, west, north, east
    let box = "\(southLat),\(westLon),\(northLat),\(eastLon)"

    // This is the JSON query.
    // ( ) is a union, so we get anything as long as it matches any line.
    // [ ] are filters on the tags of each OSM element.
    // node is a single point, while way is a line.
    let query = """
    [out:json][timeout:60];
    (
      // Crossings: points tagged highway=crossing, and lines tagged footway=crossing
      node["highway"="crossing"](\(box));
      way["footway"="crossing"](\(box));
      // Audible signals: any node that has the traffic_signals:sound tag
      node["traffic_signals:sound"](\(box));
      // Tactile paving: any node or way that has the tactile_paving tag
      node["tactile_paving"](\(box));
      way["tactile_paving"](\(box));
      // Curbs: nodes tagged barrier=kerb, or any node with a kerb tag
      node["barrier"="kerb"](\(box));
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

// Build the query and print it so we can copy it into overpass-turbo.eu to test it
let query = makeQuery()
print("")
print("Overpass query:")
print(query)


// Step 3: Count feature types and document coverage gaps

// Folder where the output files get saved (relative to where you run the script)
let outputFolder = "Data/AccessibilityExport"

// Overpass server we ask for the data
let overpassURL = "https://overpass-api.de/api/interpreter"

// Feature types we care about. Used for counting.
let allFeatureTypes = ["crossing", "audible_signal", "tactile_paving", "curb", "elevator", "entrance"]

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

// The center point of a way
struct OverpassCenter: Codable {
    let lat: Double
    let lon: Double
}

// Here, I'm looking at the tags of an element and deciding which feature types it has.
func findFeatureTypes(tags: [String: String]) -> [String] {
    var types: [String] = []
    
    if tags["highway"] == "crossing" || tags["footway"] == "crossing" {
        types.append("crossing")
    }

    if tags["traffic_signals:sound"] != nil {
        types.append("audible_signal")
    }
    
    if tags["tactile_paving"] != nil {
        types.append("tactile_paving")
    }

    if tags["barrier"] == "kerb" || tags["kerb"] != nil {
        types.append("curb")
    }

    if tags["highway"] == "elevator" {
        types.append("elevator")
    }

    if tags["entrance"] != nil {
        types.append("entrance")
    }

    return types
}

// Send the query to Overpass and give back the raw answer.
func fetchFromOverpass(query: String) async -> Data? {
    // Make a URL object out of the string
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
        
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode != 200 {
                print("Overpass gave status code \(httpResponse.statusCode). Try again in a minute.")
                return nil
            }
        }
        return data
    } catch {
        print("The request failed: \(error)")
        return nil
    }
}

// Turn the raw JSON data into our OverpassResponse struct
func decodeResponse(data: Data) -> OverpassResponse? {
    do {
        let decoder = JSONDecoder()
        let response = try decoder.decode(OverpassResponse.self, from: data)
        return response
    } catch {
        print("Could not read the Overpass JSON: \(error)")
        return nil
    }
}

func countType(elements: [OverpassElement], type: String) -> Int {
    var count = 0
    for element in elements {
        let tags = element.tags ?? [:]
        let types = findFeatureTypes(tags: tags)
        if types.contains(type) {
            count += 1
        }
    }
    return count
}

func countTypeWithTag(elements: [OverpassElement], type: String, tag: String) -> Int {
    var count = 0
    for element in elements {
        let tags = element.tags ?? [:]
        let types = findFeatureTypes(tags: tags)
        if types.contains(type) && tags[tag] != nil {
            count += 1
        }
    }
    return count
}

func percent(part: Int, whole: Int) -> String {
    if whole == 0 {
        return "n/a"
    }
    let value = Double(part) / Double(whole) * 100
    return String(format: "%.0f%%", value)
}

// Write the coverage summary
func makeSummary(elements: [OverpassElement]) -> String {
    var text = "# Accessibility Data Coverage Summary\n\n"
    text += "- Test area: \(testAreaName)\n"
    text += "- Bounding box (south, west, north, east): \(southLat), \(westLon), \(northLat), \(eastLon)\n"
    text += "- Total elements found: \(elements.count)\n\n"

    // Table with the count for each feature type.
    text += "## Feature counts\n\n| Feature type | Count |\n|---|---|\n"
    var emptyTypes: [String] = []
    for type in allFeatureTypes {
        let count = countType(elements: elements, type: type)
        text += "| \(type) | \(count) |\n"
        if count == 0 {
            emptyTypes.append(type)
        }
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
        if findFeatureTypes(tags: tags).contains("crossing") && tags["crossing"] == "traffic_signals" {
            signalCrossings += 1
            if tags["traffic_signals:sound"] != nil {
                signalCrossingsWithSound += 1
            }
        }
    }
    text += "- signalized crossings with a traffic_signals:sound tag: \(signalCrossingsWithSound) of \(signalCrossings) (\(percent(part: signalCrossingsWithSound, whole: signalCrossings)))\n"

    text += "\n## Feature types with nothing found\n\n"
    if emptyTypes.isEmpty {
        text += "- None, every feature type has at least one feature\n"
    }
    for type in emptyTypes {
        text += "- \(type): no features found in the test area\n"
    }

    text += "\n## Notes\n\n"
    text += "- A missing tag means nobody has mapped it yet. It does NOT mean the feature is not accessible.\n"
    text += "- Lines (ways) are counted as one feature each.\n"

    return text
}

// Run step 3

// Ask Overpass for the data using the query from step 2
print("")
print("Asking Overpass for the data (this can take a bit)...")

Task {
    guard let data = await fetchFromOverpass(query: query) else {
        print("No data was received, so there is nothing to count.")
        exit(1)
    }

    guard let response = decodeResponse(data: data) else {
        exit(1)
    }
    print("Overpass sent back \(response.elements.count) elements")

    let summary = makeSummary(elements: response.elements)
    print("")
    print(summary)

    // Save the summary to a file
    do {
        try FileManager.default.createDirectory(atPath: outputFolder, withIntermediateDirectories: true)
        try summary.write(toFile: "\(outputFolder)/coverage_summary.md", atomically: true, encoding: .utf8)
        print("Saved the summary in \(outputFolder)/coverage_summary.md")
    } catch {
        print("Could not save the summary: \(error)")
        exit(1)
    }
}

// Keep the script running long enough for the async Task to finish
RunLoop.main.run()
