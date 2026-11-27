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

    /// Stadia Maps' hosted Valhalla. Every route request spends the team's credits; check Stadia's
    /// pricing page for the cost (#317 assumed 20 credits per route). With REPORT-4's staged fallback one
    /// route request can send up to 3 requests. A trip sends the plan and the Start refresh, up to 5
    /// off-route reroutes and 2 report reroutes: about 27 requests, plus any "find another way" the user
    /// asks for, which is not capped. Overage is off, so running out of credits is expected to return
    /// HTTP 429 (402 is handled too).
    /// The key ships inside the app binary: if it leaks, rotate it in the Stadia dashboard. Never add
    /// Secrets.xcconfig to GitHub, including through the web upload.
    static func stadia(apiKey: String) -> ValhallaEndpoint {
        ValhallaEndpoint(
            baseURL: URL(string: "https://api.stadiamaps.com")!, routePath: "route/v1", stadiaAPIKey: apiKey
        )
    }
}

/// The Valhalla servers to ask, in order, come from the ROUTING_SERVERS build setting through Info.plist: names
/// separated by commas, set in Shared.xcconfig and overridable in Secrets.xcconfig. Apple Maps is always asked last
/// and can't be configured away.
enum RoutingConfig {
    /// The servers asked when ROUTING_SERVERS names none this build knows.
    static let defaultServers = ["stadia", "fossgis"]

    /// Read at launch, so it must never crash.
    static var servers: [ValhallaEndpoint] {
        servers(from: Bundle.main.object(forInfoDictionaryKey: "RoutingServers"), apiKey: StadiaConfig.apiKey)
    }

    /// `stadia` is dropped without a usable key, so a build made without one still routes through the rest, and if
    /// that leaves none, FOSSGIS is asked rather than none. Unknown names are ignored, a name given twice is asked
    /// once, at its first place, and a value naming no known server gives `defaultServers`.
    static func servers(from value: Any?, apiKey: String?) -> [ValhallaEndpoint] {
        let names = ((value as? String) ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let known = names.filter { name in
            guard name == "stadia" || name == "fossgis" else {
                log.error("Unknown routing server \(name, privacy: .public) in ROUTING_SERVERS, ignoring it")
                return false
            }
            return true
        }
        var seen: Set<String> = []
        let servers: [ValhallaEndpoint] = (known.isEmpty ? defaultServers : known).filter { seen.insert($0).inserted }
            .compactMap { name in
                guard name == "stadia" else { return .publicDemo }
                if let apiKey { return .stadia(apiKey: apiKey) }
                log.error("STADIA_API_KEY missing from Secrets.xcconfig; skipping Stadia")
                return nil
            }
        guard servers.isEmpty else { return servers }
        log.error("ROUTING_SERVERS leaves no Valhalla server without STADIA_API_KEY; asking FOSSGIS so routes still avoid stairs")
        return [.publicDemo]
    }
}

/// The Stadia Maps API key comes from the untracked Secrets.xcconfig (STADIA_API_KEY) through Info.plist.
enum StadiaConfig {
    /// Nil until the member has added STADIA_API_KEY to their AccessAble/Config/Secrets.xcconfig.
    static var apiKey: String? { apiKey(from: Bundle.main.object(forInfoDictionaryKey: "StadiaAPIKey")) }

    /// Text copied from Secrets.example.xcconfig that was never replaced with a real key.
    private static let placeholders: Set<String> = ["paste-your-key-here", "your_key", "your-key", "your_api_key"]

    /// An unset build setting reaches Info.plist as "" or, if unexpanded, as "$(STADIA_API_KEY)".
    /// xcconfig keeps quotes around a value, so they are stripped. Placeholders count as no key.
    static func apiKey(from value: Any?) -> String? {
        guard var raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if raw.count >= 2, let first = raw.first, first == raw.last, first == "\"" || first == "'" {
            raw = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !raw.isEmpty, !raw.contains("$("), !(raw.hasPrefix("<") && raw.hasSuffix(">")),
              !placeholders.contains(raw.lowercased()) else { return nil }
        return raw
    }
}
