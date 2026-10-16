import Foundation

/// Decodes Valhalla's default polyline6 geometry without changing vertex order.
enum ValhallaGeometryDecoder {
    enum DecodeError: Error, Equatable {
        case unsuccessfulRoute
        case missingGeometry
        case malformedPolyline
        case invalidCoordinate
        case missingManeuvers
        case invalidManeuverIndex
        case maneuversOutOfOrder
        case unsupportedManeuverType(Int)
        case unsupportedUnits
        case missingMetrics
        case invalidMetrics
        case unexpectedLegCount
    }

    /// Returns one coordinate array per leg; maneuver indices are local to each leg.
    static func decodeLegs(from data: Data) throws -> [[GeoCoordinate]] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.trip.status == 0 else { throw DecodeError.unsuccessfulRoute }
        guard !response.trip.legs.isEmpty else { throw DecodeError.missingGeometry }
        return try response.trip.legs.map { try decodePolyline($0.shape) }
    }

    /// A leg's steps index into this leg's coordinates, not a flattened trip.
    struct DecodedLeg {
        let coordinates: [GeoCoordinate]
        let steps: [RouteStep]
    }

    /// Decodes geometry and instructions together; step indices are local to each leg.
    static func decodeLegsWithManeuvers(from data: Data) throws -> [DecodedLeg] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return try decodeManeuverLegs(response)
    }

    private static func decodeManeuverLegs(_ response: Response) throws -> [DecodedLeg] {
        guard response.trip.status == 0 else { throw DecodeError.unsuccessfulRoute }
        guard !response.trip.legs.isEmpty else { throw DecodeError.missingGeometry }
        return try response.trip.legs.map { leg in
            let coordinates = try decodePolyline(leg.shape)
            guard let maneuvers = leg.maneuvers, !maneuvers.isEmpty else {
                throw DecodeError.missingManeuvers
            }
            var previousIndex = -1
            let steps = try maneuvers.map { maneuver in
                guard coordinates.indices.contains(maneuver.beginShapeIndex),
                      coordinates.indices.contains(maneuver.endShapeIndex),
                      maneuver.endShapeIndex >= maneuver.beginShapeIndex else {
                    throw DecodeError.invalidManeuverIndex
                }
                guard maneuver.beginShapeIndex >= previousIndex else {
                    throw DecodeError.maneuversOutOfOrder
                }
                previousIndex = maneuver.beginShapeIndex
                let verbal = maneuver.verbalPreTransitionInstruction?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return RouteStep(
                    kind: try maneuverKind(for: maneuver.type),
                    coordinateIndex: maneuver.beginShapeIndex,
                    instruction: maneuver.instruction,
                    spokenInstruction: verbal.flatMap { $0.isEmpty ? nil : $0 }
                        ?? maneuver.instruction
                )
            }
            return DecodedLeg(coordinates: coordinates, steps: steps)
        }
    }

    /// Units are in the property names so values never get converted twice.
    struct Metrics {
        let distanceMetres: Double
        let durationSeconds: Double
    }

    struct NormalizedLeg {
        let geometry: DecodedLeg
        let metrics: Metrics
        /// Same order and count as geometry.steps.
        let maneuverMetrics: [Metrics]
    }

    struct NormalizedTrip {
        let legs: [NormalizedLeg]
        /// Valhalla's reported total; route distances come from the geometry via GeoMath.
        let metrics: Metrics
    }

    static func decodeNormalizedTrip(from data: Data) throws -> NormalizedTrip {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let geometry = try decodeManeuverLegs(response)
        let metresPerUnit: Double
        switch response.trip.units {
        case "kilometers": metresPerUnit = 1_000
        case "miles": metresPerUnit = 1_609.344
        default: throw DecodeError.unsupportedUnits
        }
        let tripMetrics = try normalize(response.trip.summary, metresPerUnit: metresPerUnit)
        let legs = try zip(response.trip.legs, geometry).map { leg, decoded in
            let metrics = try normalize(leg.summary, metresPerUnit: metresPerUnit)
            // decodeManeuverLegs has already required a nonempty maneuver array.
            guard let maneuvers = leg.maneuvers else { throw DecodeError.missingManeuvers }
            let maneuverMetrics = try maneuvers.map { maneuver in
                try normalizeValues(length: maneuver.length, time: maneuver.time,
                                    metresPerUnit: metresPerUnit)
            }
            return NormalizedLeg(geometry: decoded, metrics: metrics,
                                 maneuverMetrics: maneuverMetrics)
        }
        return NormalizedTrip(legs: legs, metrics: tripMetrics)
    }

    /// Converts a response to a two-location request. Distances are derived from the geometry by
    /// `NavigationRoute`, not taken from Valhalla.
    /// - Throws: `DecodeError`, `DecodingError`, or `NavigationRoute.ValidationError`.
    static func decodeRoute(from data: Data) throws -> NavigationRoute {
        let trip = try decodeNormalizedTrip(from: data)
        // We only ever send an origin and a destination, so any other leg count is a response we didn't ask for.
        guard trip.legs.count == 1 else { throw DecodeError.unexpectedLegCount }
        let leg = trip.legs[0].geometry
        return try NavigationRoute(coordinates: leg.coordinates, steps: leg.steps,
                                   estimatedDuration: trip.metrics.durationSeconds)
    }

    private static func normalize(_ summary: Summary?, metresPerUnit: Double) throws -> Metrics {
        guard let summary else { throw DecodeError.missingMetrics }
        return try normalizeValues(length: summary.length, time: summary.time,
                                   metresPerUnit: metresPerUnit)
    }

    private static func normalizeValues(length: Double?, time: Double?,
                                        metresPerUnit: Double) throws -> Metrics {
        guard let length, let time else { throw DecodeError.missingMetrics }
        let metres = length * metresPerUnit
        guard length.isFinite, length >= 0, metres.isFinite,
              time.isFinite, time >= 0 else { throw DecodeError.invalidMetrics }
        // Valhalla time is already in seconds: never multiply by 60.
        return Metrics(distanceMetres: metres, durationSeconds: time)
    }

    /// Collapse directional variants into the shared vocabulary. Stairs, elevators, escalators, buildings and
    /// roundabouts have no ManeuverKind yet, so they map to straight; their instruction text still names them.
    /// Anything else is rejected rather than guessed.
    private static func maneuverKind(for type: Int) throws -> ManeuverKind {
        switch type {
        case 1, 2, 3: return .depart
        case 4, 5, 6: return .arrive
        case 7, 8, 17, 22: return .straight
        // No ManeuverKind for these yet; the instruction text still names them (e.g. "Take the stairs").
        case 25, 26, 27, 39, 40, 41, 42, 43: return .straight
        case 9, 23: return .slightRight
        case 10, 11, 18, 20, 37: return .turnRight
        case 12, 13: return .uTurn
        case 14, 15, 19, 21, 38: return .turnLeft
        case 16, 24: return .slightLeft
        default: throw DecodeError.unsupportedManeuverType(type)
        }
    }

    static func decodePolyline(_ shape: String) throws -> [GeoCoordinate] {
        let bytes = Array(shape.utf8)
        guard !bytes.isEmpty else { throw DecodeError.missingGeometry }
        var index = 0
        var latitude: Int64 = 0
        var longitude: Int64 = 0
        var coordinates: [GeoCoordinate] = []

        func readDelta() throws -> Int64 {
            var result: UInt64 = 0
            var shift = 0
            while true {
                guard index < bytes.count, shift <= 30 else {
                    throw DecodeError.malformedPolyline
                }
                let character = bytes[index]
                index += 1
                guard (63...126).contains(character) else {
                    throw DecodeError.malformedPolyline
                }
                let value = UInt64(character - 63)
                result |= (value & 31) << shift
                if value < 32 {
                    let magnitude = Int64(result >> 1)
                    return result & 1 == 0 ? magnitude : ~magnitude
                }
                shift += 5
            }
        }

        while index < bytes.count {
            let latitudeDelta = try readDelta()
            let longitudeDelta = try readDelta()
            let (nextLatitude, latitudeOverflow) = latitude.addingReportingOverflow(latitudeDelta)
            let (nextLongitude, longitudeOverflow) = longitude.addingReportingOverflow(longitudeDelta)
            guard !latitudeOverflow, !longitudeOverflow else {
                throw DecodeError.malformedPolyline
            }
            latitude = nextLatitude
            longitude = nextLongitude
            // Valhalla's default precision is 6, not Google's common precision of 5.
            let coordinate = GeoCoordinate(
                latitude: Double(latitude) / 1_000_000,
                longitude: Double(longitude) / 1_000_000
            )
            guard (-90...90).contains(coordinate.latitude),
                  (-180...180).contains(coordinate.longitude) else {
                throw DecodeError.invalidCoordinate
            }
            coordinates.append(coordinate)
        }
        guard coordinates.count >= 2 else { throw DecodeError.missingGeometry }
        return coordinates
    }

    private struct Response: Decodable {
        let trip: Trip
    }

    private struct Trip: Decodable {
        let status: Int
        let legs: [Leg]
        let units: String?
        let summary: Summary?
    }

    private struct Summary: Decodable {
        let length: Double
        let time: Double
    }

    private struct Leg: Decodable {
        let shape: String
        let summary: Summary?
        // Optional so geometry-only responses (no directions) still decode.
        let maneuvers: [ValhallaManeuver]?
    }

    private struct ValhallaManeuver: Decodable {
        let length: Double?
        let time: Double?
        let type: Int
        let instruction: String
        let beginShapeIndex: Int
        let endShapeIndex: Int
        let verbalPreTransitionInstruction: String?

        private enum CodingKeys: String, CodingKey {
            case type, instruction, length, time
            case beginShapeIndex = "begin_shape_index"
            case endShapeIndex = "end_shape_index"
            case verbalPreTransitionInstruction = "verbal_pre_transition_instruction"
        }
    }
}
