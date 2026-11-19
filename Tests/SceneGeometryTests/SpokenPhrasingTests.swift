import Testing
@testable import SceneGeometry

@Test("T48 - metric distance stays in metres")
func metricDistanceUsesMetres() {
    #expect(
        SpokenPhrasing.shortDistance(
            2.0,
            usesMetricUnits: true
        ) == "2 metres"
    )
}

@Test("T48 - imperial distance uses feet")
func imperialDistanceUsesFeet() {
    #expect(
        SpokenPhrasing.shortDistance(
            2.0,
            usesMetricUnits: false
        ) == "6.5 feet"
    )
}

@Test("T48 - imperial distance uses singular foot")
func imperialDistanceUsesSingularFoot() {
    #expect(
        SpokenPhrasing.shortDistance(
            0.3048,
            usesMetricUnits: false
        ) == "1 foot"
    )
}

@Test("T48 - spoken imperial distance uses feet")
func spokenImperialDistanceUsesFeet() {
    #expect(
        SpokenPhrasing.distance(
            1.0,
            usesMetricUnits: false
        ) == "about 3.5 feet"
    )
}
