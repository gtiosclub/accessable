import Foundation

// Exports the street crossings on the Georgia Tech campus, with how each is controlled and whether its signal is
// audible, from the OpenStreetMap accessibility export. The app bundles the result, so trips can say a crosswalk is
// ahead (NAV-6).
// Run from the repository root: swift Scripts/CampusCrossings/ExportCampusCrossings.swift

let inputPath = "Data/AccessibilityExport/accessibility_export.json"
let outputPath = "AccessAble/AccessAble/Resources/Maps/campus-crossings.json"

struct AccessibilityExport: Decodable {
    let source: String
    let license: String
    let exportDate: String
    let features: [Feature]
}

struct Feature: Decodable {
    let featureTypes: [String]
    let latitude: Double
    let longitude: Double
    let tags: [String: String]
}

struct Export: Encodable {
    let source: String
    let license: String
    let exportDate: String
    let crossings: [Crossing]
}

struct Crossing: Encodable {
    let latitude: Double
    let longitude: Double
    /// signals, marked, unmarked or unknown.
    let control: String
    let audibleSignal: Bool
}

// 7 decimals is about 1 cm, and keeps the file small
func rounded(_ value: Double) -> Double {
    (value * 10_000_000).rounded() / 10_000_000
}

/// The first rule that matches: a signal is the most useful thing to know, and "no markings" overrides a crossing
/// kind such as uncontrolled that doesn't say either way.
func control(of tags: [String: String]) -> String {
    let crossing = tags["crossing"]
    let markings = tags["crossing:markings"]
    if crossing == "traffic_signals" || tags["crossing:signals"] == "yes" { return "signals" }
    if crossing == "unmarked" || markings == "no" { return "unmarked" }
    if ["marked", "zebra", "uncontrolled"].contains(crossing) || markings != nil { return "marked" }
    return "unknown"
}

print("Reading \(inputPath)…")
let input = try JSONDecoder().decode(AccessibilityExport.self, from: Data(contentsOf: URL(fileURLWithPath: inputPath)))

let crossings = input.features
    .filter { $0.featureTypes.contains("crossing") }
    .map {
        Crossing(latitude: rounded($0.latitude), longitude: rounded($0.longitude), control: control(of: $0.tags),
                 audibleSignal: $0.tags["traffic_signals:sound"] == "yes")
    }
    // every field breaks ties, so re-running gives the same file
    .sorted {
        ($0.latitude, $0.longitude, $0.control, $0.audibleSignal ? 1 : 0)
            < ($1.latitude, $1.longitude, $1.control, $1.audibleSignal ? 1 : 0)
    }

let export = Export(source: input.source, license: input.license, exportDate: input.exportDate, crossings: crossings)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try FileManager.default.createDirectory(
    at: URL(fileURLWithPath: outputPath).deletingLastPathComponent(), withIntermediateDirectories: true
)
try encoder.encode(export).write(to: URL(fileURLWithPath: outputPath))

print("Wrote \(outputPath)")
print("\(crossings.count) crossings")
for kind in ["signals", "marked", "unmarked", "unknown"] {
    print("\(kind): \(crossings.filter { $0.control == kind }.count)")
}
print("with audible signals: \(crossings.filter(\.audibleSignal).count)")
