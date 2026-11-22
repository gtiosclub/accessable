import Foundation

/// The Valhalla server the app asks for walking routes.
struct ValhallaEndpoint: Sendable {
    var baseURL: URL
    /// Identifies us to shared servers, which is expected on the free public one.
    var userAgent = "AccessAble (GT iOS Club student project)"
    /// Path of the route service under `baseURL`: "route" on a plain Valhalla server, "route/v1" on Stadia.
    var routePath = "route"
    /// Sent as the `api_key` query parameter when set. Never log it.
    var apiKey: String? = nil

    /// Where route requests go.
    var routeURL: URL {
        let url = baseURL.appending(path: routePath)
        guard let apiKey, !apiKey.isEmpty else { return url }
        return url.appending(queryItems: [URLQueryItem(name: "api_key", value: apiKey)])
    }

    /// Free FOSSGIS demo server: fair use only (about 1 request per second), no uptime guarantee.
    static let publicDemo = ValhallaEndpoint(baseURL: URL(string: "https://valhalla1.openstreetmap.de")!)

    /// Stadia Maps' hosted Valhalla. The free plan is non-commercial (academic use included), its monthly credits
    /// are shared by every request, and going over returns errors rather than charges. A standard route request
    /// costs 20 credits, so keep the reroute throttle.
    static func stadia(apiKey: String) -> ValhallaEndpoint {
        ValhallaEndpoint(baseURL: URL(string: "https://api.stadiamaps.com")!, routePath: "route/v1", apiKey: apiKey)
    }

    /// Stadia when the build has a key, from `Secrets.xcconfig` through the `StadiaAPIKey` Info.plist entry;
    /// otherwise the public demo server, so a clone without the secrets file still routes.
    static var configured: ValhallaEndpoint {
        configured(apiKey: Bundle.main.object(forInfoDictionaryKey: "StadiaAPIKey") as? String)
    }

    /// An empty key, the example file's placeholder, or an unexpanded `$(STADIA_API_KEY)` counts as no key.
    static func configured(apiKey: String?) -> ValhallaEndpoint {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty, !key.hasPrefix("$("), key != "paste-your-key-here" else { return publicDemo }
        return stadia(apiKey: key)
    }
}
