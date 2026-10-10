import CoreLocation
import Foundation

struct LocationSample: Codable, Equatable, Sendable {
    var coordinate: GeoCoordinate
    /// Radius of uncertainty in metres.
    var horizontalAccuracy: Double
    var timestamp: Date
    /// Metres per second.
    var speed: Double? = nil
    /// Metres per second.
    var speedAccuracy: Double? = nil
    /// Direction of travel (not where the phone points) in degrees clockwise from true north, 0..<360.
    var course: Double? = nil
    /// Degrees.
    var courseAccuracy: Double? = nil
}

extension LocationSample {
    /// Fails when the fix itself is invalid.
    init?(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0 else { return nil }
        self.init(
            coordinate: GeoCoordinate(location.coordinate),
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp,
            speed: validReading(location.speed),
            speedAccuracy: validReading(location.speedAccuracy),
            course: validReading(location.course),
            courseAccuracy: validReading(location.courseAccuracy)
        )
    }
}

/// Where the top of the phone points.
struct HeadingSample: Codable, Equatable, Sendable {
    /// Degrees clockwise from true north, 0..<360. `nil` when true north is unavailable.
    var trueHeading: Double?
    /// Degrees clockwise from magnetic north, 0..<360.
    var magneticHeading: Double
    /// Maximum deviation in degrees.
    var accuracy: Double
    var timestamp: Date
}

extension HeadingSample {
    /// Fails when the reading is invalid.
    init?(_ heading: CLHeading) {
        guard heading.headingAccuracy >= 0 else { return nil }
        self.init(
            trueHeading: validReading(heading.trueHeading),
            magneticHeading: heading.magneticHeading,
            accuracy: heading.headingAccuracy,
            timestamp: heading.timestamp
        )
    }
}

/// Core Location reports an invalid reading as a negative value.
private func validReading(_ value: Double) -> Double? {
    value >= 0 ? value : nil
}

enum LocationAuthorization: Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    /// `preciseAccuracy` is false when the user turned off Precise Location.
    case authorized(preciseAccuracy: Bool)
}

struct Destination: Codable, Equatable, Sendable {
    var name: String
    var coordinate: GeoCoordinate
    var address: String? = nil
}

struct SearchSuggestion: Identifiable, Equatable, Sendable {
    let title: String
    let subtitle: String

    var id: String { "\(title)\n\(subtitle)" }
}

enum DestinationSearchError: Error, Equatable, Sendable {
    case staleSuggestion
    case noMatch
}

struct RouteOptions: Equatable, Sendable {
    /// Metres per second, greater than 0. Valhalla takes km/h, so its client converts.
    var walkingSpeed: Double = 1.2
}

enum RoutingError: Error, Equatable, Sendable {
    case noRouteFound
    case serverUnavailable
    /// The response could not be decoded or failed `NavigationRoute` validation.
    case invalidResponse
}

struct RouteStep: Codable, Equatable, Sendable {
    var kind: ManeuverKind
    /// Index into `NavigationRoute.coordinates` where this maneuver begins.
    var coordinateIndex: Int
    /// Display text from the routing engine.
    var instruction: String
    /// Text for speech.
    var spokenInstruction: String
}

/// Always valid: created and decoded only through the validating init, which derives the distances.
struct NavigationRoute: Codable, Equatable, Sendable {
    let coordinates: [GeoCoordinate]
    let steps: [RouteStep]
    /// Seconds.
    let estimatedDuration: Double
    /// Metres from the start to each coordinate. Same count as `coordinates`; starts at 0.
    let cumulativeDistances: [Double]

    enum ValidationError: Error, Equatable, Sendable {
        case tooFewCoordinates
        case invalidCoordinate(index: Int)
        case missingArrival
        case stepIndexOutOfRange(stepIndex: Int)
        case stepsOutOfOrder(stepIndex: Int)
        case invalidDuration
    }

    init(coordinates: [GeoCoordinate], steps: [RouteStep], estimatedDuration: Double) throws(ValidationError) {
        guard coordinates.count >= 2 else { throw .tooFewCoordinates }
        // Range checks also reject NaN and infinity.
        if let index = coordinates.firstIndex(where: {
            !(-90.0...90.0).contains($0.latitude) || !(-180.0...180.0).contains($0.longitude)
        }) {
            throw .invalidCoordinate(index: index)
        }
        guard steps.last?.kind == .arrive else { throw .missingArrival }
        guard estimatedDuration.isFinite, estimatedDuration >= 0 else { throw .invalidDuration }
        for (index, step) in steps.enumerated() {
            guard coordinates.indices.contains(step.coordinateIndex) else {
                throw .stepIndexOutOfRange(stepIndex: index)
            }
            if index > 0, step.coordinateIndex < steps[index - 1].coordinateIndex {
                throw .stepsOutOfOrder(stepIndex: index)
            }
        }

        var distances: [Double] = [0]
        var total = 0.0
        for (start, end) in zip(coordinates, coordinates.dropFirst()) {
            total += CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            distances.append(total)
        }

        self.coordinates = coordinates
        self.steps = steps
        self.estimatedDuration = estimatedDuration
        self.cumulativeDistances = distances
    }

    /// Metres.
    var totalDistance: Double { cumulativeDistances[cumulativeDistances.count - 1] }

    // Only the inputs are encoded; decoding re-runs validation and re-derives the distances.
    private enum CodingKeys: String, CodingKey {
        case coordinates
        case steps
        case estimatedDuration
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let coordinates = try container.decode([GeoCoordinate].self, forKey: .coordinates)
        let steps = try container.decode([RouteStep].self, forKey: .steps)
        let estimatedDuration = try container.decode(Double.self, forKey: .estimatedDuration)
        do {
            try self.init(coordinates: coordinates, steps: steps, estimatedDuration: estimatedDuration)
        } catch {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid NavigationRoute: \(error)",
                underlyingError: error
            ))
        }
    }
}

/// Fixtures for previews, placeholder services, and tests.
enum MapsSamples {
    static let origin = GeoCoordinate(latitude: 33.775, longitude: -84.399)
    static let destination = Destination(
        name: "Sample entrance",
        coordinate: GeoCoordinate(latitude: 33.776, longitude: -84.399),
        address: "Sample campus walkway"
    )
    static let location = LocationSample(
        coordinate: origin,
        horizontalAccuracy: 5,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        speed: 1.25,
        course: 0
    )
    static let heading = HeadingSample(
        trueHeading: 0,
        magneticHeading: 5,
        accuracy: 10,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000)
    )
    // Static, known-good data, so validation cannot fail.
    static let route = try! NavigationRoute(
        coordinates: [origin, destination.coordinate],
        steps: [
            RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Head north",
                      spokenInstruction: "Continue north along the walkway."),
            RouteStep(kind: .arrive, coordinateIndex: 1, instruction: "Arrive at Sample entrance",
                      spokenInstruction: "You have reached the sample entrance."),
        ],
        estimatedDuration: 88.8
    )
}
