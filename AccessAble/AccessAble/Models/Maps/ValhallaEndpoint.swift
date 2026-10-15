import Foundation

/// The Valhalla server the app asks for walking routes.
struct ValhallaEndpoint: Sendable {
    var baseURL: URL
    /// Identifies us to shared servers, which is expected on the free public one.
    var userAgent = "AccessAble (GT iOS Club student project)"

    /// Free FOSSGIS demo server: fair use only (about 1 request per second), no uptime guarantee.
    static let publicDemo = ValhallaEndpoint(baseURL: URL(string: "https://valhalla1.openstreetmap.de")!)
}
