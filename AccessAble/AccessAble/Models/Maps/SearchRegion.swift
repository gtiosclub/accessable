import Foundation

struct SearchRegion: Equatable, Sendable {
    var center: GeoCoordinate
    /// Metres.
    var radius: Double

    /// How far the user must move before the search region recentres (metres).
    static let recenterDistance: Double = 1_000

    // Campus fallback when there is no fix yet; also the default search radius.
    static let georgiaTech = SearchRegion(
        center: GeoCoordinate(latitude: 33.7756, longitude: -84.3963),
        radius: 5_000
    )

    /// Region centred on `coordinate` with the campus search radius.
    static func around(_ coordinate: GeoCoordinate) -> SearchRegion {
        SearchRegion(center: coordinate, radius: georgiaTech.radius)
    }
}
