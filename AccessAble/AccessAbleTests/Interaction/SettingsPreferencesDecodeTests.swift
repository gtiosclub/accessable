import Foundation
import Testing
@testable import AccessAble

struct SettingsPreferencesDecodeTests {
    @Test
    func decodesSavedSettingsWithoutPointToScan() throws {
        let json = """
        {
          "phoneAimingHelp": false,
          "usesMetricUnits": true,
          "autoRepeat": "once",
          "prioritizedTopics": ["directions"],
          "unpromptedTopics": ["structureBasics"],
          "promptedTopics": ["signsAndText"],
          "usesSystemScreenReader": false,
          "quickSettingsEnabled": false
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SettingsPreferences.self, from: json)
        #expect(decoded.pointToScan == false)
        #expect(decoded.phoneAimingHelp == false)
        #expect(decoded.usesMetricUnits == true)
        #expect(decoded.autoRepeat == .once)
        #expect(decoded.prioritizedTopics == [.directions])
        #expect(decoded.unpromptedTopics == [.structureBasics])
        #expect(decoded.promptedTopics == [.signsAndText])
        #expect(decoded.usesSystemScreenReader == false)
        #expect(decoded.quickSettingsEnabled == false)
    }

    @Test
    func missingFieldsTakeTheirDefaults() throws {
        let json = #"{ "phoneAimingHelp": false, "autoRepeat": "twice" }"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SettingsPreferences.self, from: json)
        var expected = SettingsPreferences.default
        expected.phoneAimingHelp = false
        expected.autoRepeat = .twice
        #expect(decoded == expected)
    }

    @Test
    func emptySettingsDecodeAsDefaults() throws {
        let decoded = try JSONDecoder().decode(SettingsPreferences.self, from: Data("{}".utf8))
        #expect(decoded == SettingsPreferences.default)
    }

    @Test
    func roundTripsPointToScan() throws {
        var preferences = SettingsPreferences.default
        preferences.pointToScan = true
        let decoded = try JSONDecoder().decode(SettingsPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded == preferences)
    }
}
