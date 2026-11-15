import Foundation
import Testing
@testable import AccessAble

struct DistanceFormatterTests {
    @Test(arguments: [
        (0.0, "about 25 feet"),
        (7.62, "about 25 feet"),
        (40, "about 125 feet"),
        (45.72, "about 150 feet"),
        // 489 ft rounds to 500 ft, so it is said in miles
        (149, "about 0.1 miles"),
        (1_609.344, "about 1 mile"),
        (2_414, "about 1.5 miles"),
    ])
    func feetIn25FootStepsThenTenthsOfAMile(_ metres: Double, _ expected: String) {
        #expect(DistanceFormatter.imperial.spoken(metres) == expected)
    }

    @Test(arguments: [
        (3.0, "about 10 metres"),
        (352, "about 350 metres"),
        (996, "about 1 kilometre"),
        (1_840, "about 1.8 kilometres"),
    ])
    func metresIn10MetreStepsThenTenthsOfAKilometre(_ metres: Double, _ expected: String) {
        #expect(DistanceFormatter.metric.spoken(metres) == expected)
    }

    @Test
    func writtenUsesSymbols() {
        #expect(DistanceFormatter.imperial.written(40) == "125 ft")
        #expect(DistanceFormatter.imperial.written(2_414) == "1.5 mi")
        #expect(DistanceFormatter.metric.written(80) == "80 m")
        #expect(DistanceFormatter.metric.written(1_840) == "1.8 km")
    }

    @Test
    func automaticFollowsTheRegion() {
        #expect(DistanceUnits.automatic.system(for: Locale(identifier: "en_US")) == .imperial)
        #expect(DistanceUnits.automatic.system(for: Locale(identifier: "fr_FR")) == .metric)
        #expect(DistanceUnits.feet.system(for: Locale(identifier: "fr_FR")) == .imperial)
        #expect(DistanceUnits.metres.system(for: Locale(identifier: "en_US")) == .metric)
    }

    @Test
    func profilesSavedBeforeTheSettingLoadAsAutomatic() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(GuidanceProfile.blind)) as? [String: Any])
        json.removeValue(forKey: "distanceUnits")
        let profile = try JSONDecoder().decode(GuidanceProfile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(profile.distanceUnits == .automatic)
    }
}
