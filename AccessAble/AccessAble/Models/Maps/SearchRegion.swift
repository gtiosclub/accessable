import Foundation

struct SearchRegion: Equatable, Sendable {
    var center: GeoCoordinate
    /// Metres.
    var radius: Double

    // walking distance around campus; MapKit drops results outside it
    static let georgiaTech = SearchRegion(
        center: GeoCoordinate(latitude: 33.7756, longitude: -84.3963),
        radius: 5_000
    )
}
