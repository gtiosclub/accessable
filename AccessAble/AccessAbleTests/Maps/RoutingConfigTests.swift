import Foundation
import Testing
@testable import AccessAble

struct RoutingConfigTests {
    private static let stadia = ValhallaEndpoint.stadia(apiKey: "abc").baseURL
    private static let fossgis = ValhallaEndpoint.publicDemo.baseURL

    private func servers(_ value: Any?, apiKey: String? = "abc") -> [URL] {
        RoutingConfig.servers(from: value, apiKey: apiKey).map(\.baseURL)
    }

    @Test(arguments: [nil, "", "  ", ",", "$(ROUTING_SERVERS)", "osrm"] as [String?])
    func namingNoKnownServerGivesStadiaThenFossgis(_ value: String?) {
        #expect(servers(value) == [Self.stadia, Self.fossgis])
    }

    @Test
    func defaultSendsTheStadiaKey() {
        #expect(RoutingConfig.servers(from: nil, apiKey: "abc").map(\.stadiaAPIKey) == ["abc", nil])
    }

    @Test
    func fossgisOnly() {
        #expect(servers("fossgis") == [Self.fossgis])
    }

    @Test
    func keepsTheConfiguredOrder() {
        #expect(servers("fossgis,stadia") == [Self.fossgis, Self.stadia])
    }

    @Test(arguments: [nil, "", "paste-your-key-here", "$(STADIA_API_KEY)"] as [String?])
    func stadiaIsDroppedWithoutAUsableKey(_ key: String?) {
        let apiKey = StadiaConfig.apiKey(from: key)
        #expect(servers("stadia,fossgis", apiKey: apiKey) == [Self.fossgis])
        #expect(servers(nil, apiKey: apiKey) == [Self.fossgis])
        #expect(servers("stadia", apiKey: apiKey) == [Self.fossgis])
    }

    @Test
    func aServerNamedTwiceIsAskedOnceAtItsFirstPlace() {
        #expect(servers("stadia,stadia") == [Self.stadia])
        #expect(servers("fossgis, stadia ,FOSSGIS,stadia") == [Self.fossgis, Self.stadia])
    }

    @Test
    func unknownNamesAreIgnored() {
        #expect(servers("osrm,fossgis,graphhopper") == [Self.fossgis])
    }

    @Test
    func spacesAndCaseDoNotMatter() {
        #expect(servers(" Stadia , FOSSGIS\n") == [Self.stadia, Self.fossgis])
    }
}
