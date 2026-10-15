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

extension LocationAuthorization {
    init(status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .restricted:
            self = .restricted
        case .denied:
            self = .denied
        case .authorizedWhenInUse, .authorizedAlways:
            self = .authorized(preciseAccuracy: accuracy == .fullAccuracy)
        @unknown default:
            // Safest reading of a status we don't know yet: don't proceed as if location works.
            self = .denied
        }
    }
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
    case suggestionsUnavailable
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

        self.coordinates = coordinates
        self.steps = steps
        self.estimatedDuration = estimatedDuration
        self.cumulativeDistances = GeoMath.cumulativeDistances(along: coordinates)
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

/// Where a point falls on a `NavigationRoute`.
struct RouteProjection: Equatable, Sendable {
    /// Closest point on the route.
    let coordinate: GeoCoordinate
    /// The segment holding `coordinate`, from `coordinates[segmentIndex]` to `coordinates[segmentIndex + 1]`.
    let segmentIndex: Int
    /// Metres from the route start to `coordinate`.
    let distanceAlongRoute: Double
    /// Metres from `coordinate` to the point: negative left of the direction of travel, positive right.
    let sideOffset: Double
}

extension NavigationRoute {
    /// Closest point on the route to `point`, exact on `GeoMath`'s sphere.
    ///
    /// - `segments` restricts the search to those segment indices; it defaults to the whole route. It must be
    ///   non-empty and within `0..<coordinates.count - 1`, or this traps.
    /// - Before the start or past the end of the searched segments, the projection clamps to the endpoint.
    /// - When the foot (where the point lands on the route) is within about 1 mm of a vertex, the projection is that
    ///   vertex: `distanceAlongRoute` equals its `cumulativeDistances` entry exactly, and `sideOffset` is the distance
    ///   to it.
    /// - `abs(sideOffset)` equals `GeoMath.distance(from: point, to: coordinate)` exactly, signed by the side of the
    ///   chosen segment's great circle the point is on, even when clamped. A segment under about 1 mm long counts
    ///   as its start point and has no side, so its offset is never negative.
    /// - Treat the sign as unreliable when `sideOffset` is tiny or the foot is a vertex: at a corner it comes from
    ///   whichever segment won.
    /// - Only exactly equal distances (identical geometry) tie, and resolve to the lowest index; near-ties go to
    ///   whichever segment rounding favours.
    /// - Past the end of a route whose last segment is under about 1 mm, `distanceAlongRoute` can fall up to 1 mm
    ///   short of `totalDistance`, so compare arrival with a tolerance.
    /// - A NaN or infinite point gives NaN `distanceAlongRoute` and `sideOffset`, `coordinate` equal to the point and
    ///   `segmentIndex` equal to the first searched segment; check `isFinite` before using the result.
    func projection(of point: GeoCoordinate, segments: Range<Int>? = nil) -> RouteProjection {
        GeoMath.project(point, onto: coordinates, cumulativeDistances: cumulativeDistances,
                        segments: segments ?? 0..<coordinates.count - 1)
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
