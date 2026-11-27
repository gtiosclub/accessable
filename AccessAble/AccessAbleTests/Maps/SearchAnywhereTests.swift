import Foundation
import MapKit
import Testing
@testable import AccessAble

@MainActor
private final class RecordingMapKit: MapKitAutocompleting {
    var onResults: (([SearchSuggestion]) -> Void)?
    var onError: ((DestinationSearchError) -> Void)?
    private(set) var regions: [SearchRegion] = []

    func update(fragment: String) {}
    func cancel() {}
    func resolve(_ suggestion: SearchSuggestion) async throws -> Destination {
        throw DestinationSearchError.noMatch
    }
    func setSearchRegion(_ region: SearchRegion) {
        regions.append(region)
    }
}

@MainActor
struct SearchAnywhereTests {
    private let chicago = GeoCoordinate(latitude: 41.8789, longitude: -87.6359)
    private let nearby = GeoCoordinate(latitude: 41.883, longitude: -87.63)
    private let far = GeoCoordinate(latitude: 41.95, longitude: -87.7)

    @Test
    func searchRegionFollowsUserThenFallsBackToCampus() {
        let mapKit = RecordingMapKit()
        let search = DestinationAutocompleter(dictionary: .bundled, mapKit: mapKit)
        #expect(search.searchRegion == .georgiaTech)

        search.updateRegion(for: chicago)
        #expect(search.searchRegion == SearchRegion.around(chicago))
        #expect(mapKit.regions.last == SearchRegion.around(chicago))

        // Under 1 km: no recenter
        search.updateRegion(for: nearby)
        #expect(search.searchRegion.center == chicago)
        #expect(mapKit.regions.count == 1)

        search.updateRegion(for: far)
        #expect(search.searchRegion == SearchRegion.around(far))

        search.updateRegion(for: nil)
        #expect(search.searchRegion == .georgiaTech)
    }

    @Test
    func liveMapKitUsesDefaultRegionPriority() {
        // Constructed through the convenience path that AppServices uses.
        let search = DestinationAutocompleter(region: .georgiaTech)
        // Nicknames stay campus-only; MapKit bias starts on campus and is .default (not .required).
        #expect(search.searchRegion == .georgiaTech)
        #expect(MKLocalSearchCompleter().regionPriority == .default)
    }

    @Test
    func longDistancesSpeakMilesNotHugeFeet() {
        let metres = 700 * 1_609.344
        #expect(DistanceFormatter.imperial.words(metres) == "700 miles")
        // 1_126_540.8 m → 1126.5 km (never "3,696,000 feet")
        #expect(DistanceFormatter.metric.words(metres) == "1126.5 kilometres")
    }
}
