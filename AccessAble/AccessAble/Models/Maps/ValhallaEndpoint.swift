import Foundation
import os

private let log = Logger(subsystem: "AccessAble", category: "Routing")

/// The Valhalla server the app asks for walking routes.
struct ValhallaEndpoint: Sendable {
    var baseURL: URL
    /// Appended to `baseURL` to make the route URL.
    var routePath = "route"
    /// Sent as `Authorization: Stadia-Auth <key>`, so the key stays out of the URL and its logs.
    var stadiaAPIKey: String?
    /// Identifies us to shared servers, which is expected on the free public one.
    var userAgent = "AccessAble (GT iOS Club student project)"

    var routeURL: URL { baseURL.appending(path: routePath) }

    /// Free FOSSGIS demo server: fair use only (about 1 request per second), no uptime guarantee.
    static let publicDemo = ValhallaEndpoint(baseURL: URL(string: "https://valhalla1.openstreetmap.de")!)

    /// Stadia Maps' hosted Valhalla. Each route uses the team's credits; HTTP 429 means they ran out
    /// or Stadia is throttling us.
    static func stadia(apiKey: String) -> ValhallaEndpoint {
        ValhallaEndpoint(
            baseURL: URL(string: "https://api.stadiamaps.com")!, routePath: "route/v1", stadiaAPIKey: apiKey
        )
    }

    /// Stadia when this build has a key. Without one, falls back to the public demo server so a build
    /// made without the key still launches and routes. It is read at launch, so it must never crash.
    static var live: ValhallaEndpoint {
        if let key = StadiaConfig.apiKey { return .stadia(apiKey: key) }
        log.fault("STADIA_API_KEY missing from Secrets.xcconfig; routing through the public demo server")
        return .publicDemo
    }
}

/// The Stadia Maps API key comes from the untracked Secrets.xcconfig (STADIA_API_KEY) through Info.plist.
enum StadiaConfig {
    /// Nil until the member has added STADIA_API_KEY to their AccessAble/Config/Secrets.xcconfig.
    static var apiKey: String? { apiKey(from: Bundle.main.object(forInfoDictionaryKey: "StadiaAPIKey")) }

    /// An unset build setting reaches Info.plist as "" or, if unexpanded, as "$(STADIA_API_KEY)".
    static func apiKey(from value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty, !raw.contains("$(") else { return nil }
        return raw
    }
}
