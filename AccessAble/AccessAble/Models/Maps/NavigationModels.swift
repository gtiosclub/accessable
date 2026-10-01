import Foundation

// Location reading from phone
struct LocationSample: Codable, Equatable, Sendable {
    var coordinate: GeoCoordinate
    var accuracy: Double
    var timestamp: Date
    var speed: Double? = nil
    var movementCourse: Double? = nil
}

// User destination
struct Destination: Codable, Equatable, Sendable {
    var name: String
    var coordinate: GeoCoordinate
    var address: String? = nil
}

struct RouteStep: Codable, Equatable, Sendable {
    var rawInstruction: String
    var spokenInstruction: String
    var distanceFromStart: Double
}

// Complete route
struct NavigationRoute: Codable, Equatable, Sendable {
    var coordinates: [GeoCoordinate]
    var cumulativeDistances: [Double]
    var steps: [RouteStep]
    var totalDistance: Double
    var estimatedDuration: Double
}

// Use these for testing
enum MapsSamples {
    static let origin = GeoCoordinate(latitude: 33.775, longitude: -84.399)
    static let destination = Destination(
        name: "Sample entrance",
        coordinate: GeoCoordinate(latitude: 33.776, longitude: -84.399),
        address: "Sample campus walkway"
    )
    static let location = LocationSample(
        coordinate: origin,
        accuracy: 5,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        speed: 1.25,
        movementCourse: 0
    )
    static let route = NavigationRoute(
        coordinates: [origin, destination.coordinate],
        cumulativeDistances: [0, 111],
        steps: [
            RouteStep(rawInstruction: "Head north", spokenInstruction: "Continue north along the walkway.",
                      distanceFromStart: 0),
            RouteStep(rawInstruction: "Arrive", spokenInstruction: "You have reached the sample entrance.",
                      distanceFromStart: 111),
        ],
        totalDistance: 111,
        estimatedDuration: 88.8
    )
}
