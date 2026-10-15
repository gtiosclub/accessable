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

    /// ROUTE-3: decode geometry and instructions together using the same response schema.
    static func decodeLegsWithManeuvers(from data: Data) throws -> [DecodedLeg] {
        let response = try JSONDecoder().decode(Response.self, from: data)
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

    /// Collapse directional variants into the shared vocabulary. Reject unsupported
    /// types rather than silently issuing an incorrect straight-ahead cue.
    private static func maneuverKind(for type: Int) throws -> ManeuverKind {
        switch type {
        case 1, 2, 3: return .depart
        case 4, 5, 6: return .arrive
        case 7, 8, 17, 22: return .straight
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
    }

    private struct Leg: Decodable {
        let shape: String
        // Optional preserves ROUTE-2's geometry-only API for responses without directions.
        let maneuvers: [ValhallaManeuver]?
    }

    private struct ValhallaManeuver: Decodable {
        let type: Int
        let instruction: String
        let beginShapeIndex: Int
        let endShapeIndex: Int
        let verbalPreTransitionInstruction: String?

        private enum CodingKeys: String, CodingKey {
            case type, instruction
            case beginShapeIndex = "begin_shape_index"
            case endShapeIndex = "end_shape_index"
            case verbalPreTransitionInstruction = "verbal_pre_transition_instruction"
        }
    }
}
