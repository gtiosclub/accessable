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
          "unpromptedTopics": ["directions"],
          "promptedTopics": ["signsAndText"],
          "usesSystemScreenReader": true,
          "quickSettingsEnabled": false
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SettingsPreferences.self, from: json)
        #expect(decoded.pointToScan == false)
        #expect(decoded.phoneAimingHelp == false)
        #expect(decoded.autoRepeat == .once)
    }
}