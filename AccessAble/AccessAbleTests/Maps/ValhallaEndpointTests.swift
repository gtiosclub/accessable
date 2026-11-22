import Foundation
import Testing
@testable import AccessAble

struct ValhallaEndpointTests {
    @Test
    func publicDemoRouteURLIsUnchanged() {
        #expect(ValhallaEndpoint.publicDemo.routeURL.absoluteString == "https://valhalla1.openstreetmap.de/route")
    }

    @Test
    func stadiaSendsKeyAsQueryParameter() {
        let url = ValhallaEndpoint.stadia(apiKey: "test-key").routeURL
        #expect(url.absoluteString == "https://api.stadiamaps.com/route/v1?api_key=test-key")
    }

    @Test
    func configuredUsesStadiaWithAKey() {
        let endpoint = ValhallaEndpoint.configured(apiKey: " test-key\n")
        #expect(endpoint.routeURL.absoluteString == "https://api.stadiamaps.com/route/v1?api_key=test-key")
    }

    /// A clone without Secrets.xcconfig, or one with the example file copied but not filled in, still routes.
    @Test(arguments: [nil, "", "   ", "$(STADIA_API_KEY)", "paste-your-key-here"] as [String?])
    func configuredFallsBackToPublicDemoWithoutAKey(_ key: String?) {
        let endpoint = ValhallaEndpoint.configured(apiKey: key)
        #expect(endpoint.routeURL == ValhallaEndpoint.publicDemo.routeURL)
        #expect(endpoint.apiKey == nil)
    }

    private actor URLRecorder {
        private(set) var urls: [URL] = []
        func record(_ url: URL?) { if let url { urls.append(url) } }
    }

    /// The routing service itself is unchanged: only the endpoint decides where the request goes.
    @Test
    func routingServicePostsToStadiaWithTheKey() async throws {
        let recorder = URLRecorder()
        let service = ValhallaRoutingService(endpoint: .stadia(apiKey: "test-key")) { request in
            await recorder.record(request.url)
            throw URLError(.cannotConnectToHost)
        }
        await #expect(throws: RoutingError.serverUnavailable) {
            try await service.route(from: MapsSamples.origin, to: MapsSamples.destination.coordinate,
                                    options: RouteOptions())
        }
        let urls = await recorder.urls.map(\.absoluteString)
        #expect(urls == ["https://api.stadiamaps.com/route/v1?api_key=test-key"])
    }
}
