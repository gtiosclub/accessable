import Foundation
import MapKit

/// Nearby MapKit POIs for point-to-scan, fetched off the main actor.
protocol PointToScanPOIProviding: Sendable {
    func fetch(center: GeoCoordinate) async -> [PointToScanPlace]
}

actor PointToScanPOIProvider: PointToScanPOIProviding {
    /// Matches `LocationDescriber` so we don't hold MapKit buffers longer than needed elsewhere.
    static let fetchRadius: Double = 150

    func fetch(center: GeoCoordinate) async -> [PointToScanPlace] {
        await Self.load(center: center)
    }

    @concurrent private static func load(center: GeoCoordinate) async -> [PointToScanPlace] {
        let request = MKLocalPointsOfInterestRequest(center: center.clCoordinate, radius: fetchRadius)
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        var seen = Set<String>()
        return response.mapItems.compactMap { item in
            guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return nil
            }
            let coordinate = GeoCoordinate(item.location.coordinate)
            let key = "\(name)|\(coordinate.latitude)|\(coordinate.longitude)"
            guard seen.insert(key).inserted else { return nil }
            return PointToScanPlace(
                id: "mapkit:\(key)",
                name: name,
                coordinate: coordinate,
                source: .mapKit
            )
        }
    }
}

/// Fixed POIs for unit tests.
struct StubPointToScanPOIProvider: PointToScanPOIProviding {
    let places: [PointToScanPlace]

    func fetch(center: GeoCoordinate) async -> [PointToScanPlace] { places }
}