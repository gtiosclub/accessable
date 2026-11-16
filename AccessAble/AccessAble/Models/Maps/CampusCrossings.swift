import Foundation
import os

private let log = Logger(subsystem: "AccessAble", category: "Crossings")

/// A street crossing on campus from OpenStreetMap, with how it is controlled.
struct CampusCrossing: Equatable, Sendable {
    enum Control: String, Sendable {
        /// Traffic lights with a pedestrian phase.
        case signals
        /// Painted markings, or a crossing OpenStreetMap calls uncontrolled.
        case marked
        /// A place to cross with no markings.
        case unmarked
        /// Nobody has mapped how it is controlled.
        case unknown
    }

    var coordinate: GeoCoordinate
    var control: Control
    /// The signal makes a sound for when to cross. False also when nobody has mapped it.
    var audibleSignal: Bool
}

enum CampusCrossings {
    /// Built by Scripts/CampusCrossings/ExportCampusCrossings.swift. Empty if the file is missing or unreadable; trips
    /// then run without crossing callouts, and the failure is logged.
    static let all: [CampusCrossing] = {
        guard let url = Bundle.main.url(forResource: "campus-crossings", withExtension: "json") else {
            log.error("campus-crossings.json is missing from the app bundle")
            return []
        }
        do {
            return try decode(Data(contentsOf: url))
        } catch {
            log.error("Could not read campus-crossings.json: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }()

    /// A `control` this version doesn't know reads as `.unknown`, so a newer export still loads.
    static func decode(_ data: Data) throws -> [CampusCrossing] {
        try JSONDecoder().decode(Export.self, from: data).crossings.map {
            CampusCrossing(coordinate: GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude),
                           control: CampusCrossing.Control(rawValue: $0.control) ?? .unknown,
                           audibleSignal: $0.audibleSignal)
        }
    }

    private struct Export: Decodable {
        let crossings: [Crossing]
    }

    private struct Crossing: Decodable {
        let latitude: Double
        let longitude: Double
        let control: String
        let audibleSignal: Bool
    }
}
