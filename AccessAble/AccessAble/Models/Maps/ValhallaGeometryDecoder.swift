import Foundation

/// Decodes Valhalla's default polyline6 geometry without changing vertex order.
enum ValhallaGeometryDecoder {
    enum DecodeError: Error, Equatable {
        case unsuccessfulRoute
        case missingGeometry
        case malformedPolyline
        case invalidCoordinate
    }

    /// Returns one coordinate array per leg; maneuver indices are local to each leg.
    static func decodeLegs(from data: Data) throws -> [[GeoCoordinate]] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.trip.status == 0 else { throw DecodeError.unsuccessfulRoute }
        guard !response.trip.legs.isEmpty else { throw DecodeError.missingGeometry }
        return try response.trip.legs.map { try decodePolyline($0.shape) }
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
    }
}
