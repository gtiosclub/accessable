import Foundation
import Observation
import Synchronization
import Testing
@testable import AccessAble

private let origin = GeoCoordinate(latitude: 33.7740, longitude: -84.3970)
private let sampleTime = Date(timeIntervalSince1970: 1_700_000_000)

/// Yields until `condition` holds, for samples the view model receives on its own tasks.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    while !condition() { await Task.yield() }
}

/// Moves `metres` from `origin` along `bearingDegrees` (0 = north, 90 = east) so tests can
/// place targets in every 45° sector using real `GeoMath` geometry.
private func coordinate(distanceMetres: Double, bearingDegrees: Double) -> GeoCoordinate {
    let radius = 6_371_000.0
    let angular = distanceMetres / radius
    let bearing = bearingDegrees * .pi / 180
    let lat1 = origin.latitude * .pi / 180
    let lon1 = origin.longitude * .pi / 180
    let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
    let lon2 = lon1 + atan2(
        sin(bearing) * sin(angular) * cos(lat1),
        cos(angular) - sin(lat1) * sin(lat2)
    )
    return GeoCoordinate(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
}

struct CardinalDirectionTests {
    @Test(arguments: [
        (0.0, CardinalDirection.north),
        (45.0, .northeast),
        (90.0, .east),
        (135.0, .southeast),
        (180.0, .south),
        (225.0, .southwest),
        (270.0, .west),
        (315.0, .northwest),
    ])
    func eachSectorCentre(_ degrees: Double, _ expected: CardinalDirection) {
        #expect(CardinalDirection(bearing: degrees) == expected)
    }

    @Test(arguments: [
        (337.5, CardinalDirection.north), (22.4, .north),
        (22.5, .northeast), (67.4, .northeast),
        (67.5, .east), (112.4, .east),
        (112.5, .southeast), (157.4, .southeast),
        (157.5, .south), (202.4, .south),
        (202.5, .southwest), (247.4, .southwest),
        (247.5, .west), (292.4, .west),
        (292.5, .northwest), (337.4, .northwest),
    ])
    func eachSectorHoldsItsAnticlockwiseEdge(_ degrees: Double, _ expected: CardinalDirection) {
        #expect(CardinalDirection(bearing: degrees) == expected)
    }

    @Test(arguments: [(360.0, CardinalDirection.north), (-45.0, .northwest), (405.0, .northeast), (-90.0, .west)])
    func wrapsBearingsBeyondFullCircle(_ degrees: Double, _ expected: CardinalDirection) {
        #expect(CardinalDirection(bearing: degrees) == expected)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteBearingReturnsNil(_ degrees: Double) {
        #expect(CardinalDirection(bearing: degrees) == nil)
    }

    @Test(arguments: [
        (CardinalDirection.north, "north"),
        (.northeast, "northeast"),
        (.east, "east"),
        (.southeast, "southeast"),
        (.south, "south"),
        (.southwest, "southwest"),
        (.west, "west"),
        (.northwest, "northwest"),
    ])
    func eachPhrase(_ direction: CardinalDirection, _ expected: String) {
        #expect(direction.phrase == expected)
    }
}

struct SearchResultSpeechTests {
    @Test(arguments: [
        (0.0, "north"),
        (45.0, "northeast"),
        (90.0, "east"),
        (135.0, "southeast"),
        (180.0, "south"),
        (225.0, "southwest"),
        (270.0, "west"),
        (315.0, "northwest"),
    ])
    func allEightCardinalDirectionsWithoutHeading(_ bearing: Double, _ expectedDirection: String) {
        let target = coordinate(distanceMetres: 106.7, bearingDegrees: bearing) // ~350 ft
        let suggestion = SearchSuggestion(title: "Clough Commons", subtitle: "", coordinate: target)

        let spoken = SearchResultSpeech.label(
            for: suggestion,
            at: 0,
            from: origin,
            heading: nil,
            distances: .imperial
        )
        #expect(spoken == "Clough Commons, 350 feet, \(expectedDirection)")
    }

    @Test(arguments: [
        (0.0, "ahead"),
        (45.0, "slightly right"),
        (90.0, "on your right"),
        (135.0, "behind you on your right"),
        (180.0, "behind you"),
        (225.0, "behind you on your left"),
        (270.0, "on your left"),
        (315.0, "slightly left"),
    ])
    func allEightRelativeDirectionsWhenHeadingIsKnown(_ bearing: Double, _ expectedDirection: String) {
        let target = coordinate(distanceMetres: 106.7, bearingDegrees: bearing) // ~350 ft
        let suggestion = SearchSuggestion(title: "Clough Commons", subtitle: "", coordinate: target)
        let facingNorth = UserHeading(degrees: 0, source: .compass, timestamp: sampleTime)

        let spoken = SearchResultSpeech.label(
            for: suggestion,
            at: 0,
            from: origin,
            heading: facingNorth,
            distances: .imperial
        )
        #expect(spoken == "Clough Commons, 350 feet, \(expectedDirection)")
    }

    @Test func relativeDirectionRotatesWithUsersHeading() {
        // Target is northeast (45°); user faces east (90°), so target is 45° to their left.
        let target = coordinate(distanceMetres: 106.7, bearingDegrees: 45)
        let suggestion = SearchSuggestion(
            title: "Clough Commons",
            subtitle: "266 4th St NW",
            coordinate: target
        )
        let facingEast = UserHeading(degrees: 90, source: .walkingDirection, timestamp: sampleTime)

        let spoken = SearchResultSpeech.label(
            for: suggestion,
            at: 0,
            from: origin,
            heading: facingEast,
            distances: .imperial
        )
        #expect(spoken == "Clough Commons, 350 feet, slightly left, 266 4th St NW")
    }

    @Test func usesWire7UnitFormatterForMetricAndImperial() {
        let target = coordinate(distanceMetres: 120, bearingDegrees: 90)
        let suggestion = SearchSuggestion(title: "Tech Tower", subtitle: "", coordinate: target)

        let metric = SearchResultSpeech.label(for: suggestion, at: 0, from: origin, heading: nil, distances: .metric)
        let imperial = SearchResultSpeech.label(for: suggestion, at: 0, from: origin, heading: nil, distances: .imperial)

        #expect(metric == "Tech Tower, 120 metres, east")
        #expect(imperial == "Tech Tower, 400 feet, east")
    }

    @Test func speaksDistanceAndDirectionForTopFiveResultsOnly() {
        let target = coordinate(distanceMetres: 106.7, bearingDegrees: 45)
        for index in 0..<7 {
            let suggestion = SearchSuggestion(title: "Place \(index)", subtitle: "Campus", coordinate: target)
            let spoken = SearchResultSpeech.label(
                for: suggestion,
                at: index,
                from: origin,
                heading: nil,
                distances: .imperial
            )
            if index < 5 {
                #expect(spoken == "Place \(index), 350 feet, northeast, Campus")
            } else {
                #expect(spoken == "Place \(index), Campus")
            }
        }
    }

    @Test func fallsBackCleanlyWhenOriginOrCoordinateIsMissing() {
        let suggestion = SearchSuggestion(title: "Unknown Place", subtitle: "Atlanta, GA")
        let noCoordinate = SearchResultSpeech.label(for: suggestion, at: 0, from: origin, heading: nil, distances: .imperial)
        #expect(noCoordinate == "Unknown Place, Atlanta, GA")

        let withCoordinate = SearchSuggestion(
            title: "Clough Commons",
            subtitle: "266 4th St NW",
            coordinate: coordinate(distanceMetres: 106.7, bearingDegrees: 45)
        )
        let noOrigin = SearchResultSpeech.label(for: withCoordinate, at: 0, from: nil, heading: nil, distances: .imperial)
        #expect(noOrigin == "Clough Commons, 266 4th St NW")
    }
}

@MainActor
struct SearchResultSpeechIntegrationTests {
    @Test func autocompleterResolvesCoordinatesForTopFiveMapKitResultsOnly() async {
        let mapKit = StubMapKitAutocompleter()
        let emptyDictionary = CampusNicknameDictionary(places: [])
        let autocompleter = DestinationAutocompleter(dictionary: emptyDictionary, mapKit: mapKit)

        var iterator = autocompleter.suggestions().makeAsyncIterator()
        autocompleter.update(query: "coffee")

        let batch = (0..<7).map { SearchSuggestion(title: "Cafe \($0)", subtitle: "Atlanta") }
        let coords = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, origin) })
        mapKit.coordinatesByID = coords
        mapKit.onResults?(batch)

        let initial = try? await iterator.next()?.get()
        #expect(initial?.count == 7)
        #expect(initial?.allSatisfy { $0.coordinate == nil } == true)

        let enriched = try? await iterator.next()?.get()
        #expect(enriched?.count == 7)
        #expect(enriched?.prefix(5).allSatisfy { $0.coordinate == origin } == true)
        #expect(enriched?.dropFirst(5).allSatisfy { $0.coordinate == nil } == true)
        #expect(mapKit.coordinateLookups.count == 5)
    }

    @Test func autocompleterSkipsCoordinateLookupsForReplacedResults() async {
        let mapKit = StubMapKitAutocompleter()
        let emptyDictionary = CampusNicknameDictionary(places: [])
        let autocompleter = DestinationAutocompleter(dictionary: emptyDictionary, mapKit: mapKit)

        var iterator = autocompleter.suggestions().makeAsyncIterator()
        autocompleter.update(query: "coffee")

        let replaced = (0..<3).map { SearchSuggestion(title: "Cafe \($0)", subtitle: "Atlanta") }
        let current = (0..<2).map { SearchSuggestion(title: "Coffee \($0)", subtitle: "Atlanta") }
        mapKit.coordinatesByID = Dictionary(uniqueKeysWithValues: (replaced + current).map { ($0.id, origin) })
        // The second set arrives before the first one's lookups get to run.
        mapKit.onResults?(replaced)
        mapKit.onResults?(current)

        // The stream keeps only the newest set, so the first set is never seen.
        let initial = try? await iterator.next()?.get()
        #expect(initial?.map(\.title) == current.map(\.title))
        let enriched = try? await iterator.next()?.get()

        #expect(enriched?.map(\.title) == current.map(\.title))
        #expect(enriched?.allSatisfy { $0.coordinate == origin } == true)
        #expect(mapKit.coordinateLookups.map(\.title) == current.map(\.title))
    }

    @Test func placeSearchViewModelUsesHeadingWhenKnownAndCardinalWhenUnknown() async {
        let locationProvider = ControllableLocationProvider()
        var services = AppServices.preview
        services.location = locationProvider
        services.distanceSettings.units = .feet

        let target = coordinate(distanceMetres: 106.7, bearingDegrees: 45)
        let searchService = StubDestinationSearch(suggestions: [
            SearchSuggestion(title: "Clough Commons", subtitle: "", coordinate: target)
        ])
        let viewModel = PlaceSearchViewModel(services: services, search: searchService, now: { sampleTime + 1 })

        let task = Task { await viewModel.start() }
        defer { task.cancel() }

        viewModel.query = "Clough"
        viewModel.search()

        locationProvider.yieldAuthorization(.authorized(preciseAccuracy: true))
        locationProvider.yieldLocation(LocationSample(
            coordinate: origin,
            horizontalAccuracy: 5,
            timestamp: sampleTime
        ))
        await waitUntil { viewModel.suggestions.count == 1 && viewModel.location != nil }

        #expect(viewModel.heading == nil)
        #expect(viewModel.spokenLabel(for: viewModel.suggestions[0], at: 0) == "Clough Commons, 350 feet, northeast")

        // A row's label must re-render on a heading change alone.
        let labelInvalidated = Flag()
        withObservationTracking {
            _ = viewModel.spokenLabel(for: viewModel.suggestions[0], at: 0)
        } onChange: {
            labelInvalidated.raise()
        }

        // NAV-2 provides a compass heading facing east (90°); northeast (45°) is now slightly left.
        locationProvider.yieldHeading(HeadingSample(
            trueHeading: 90,
            magneticHeading: 92,
            accuracy: 10,
            timestamp: sampleTime.addingTimeInterval(0.5)
        ))
        await waitUntil { viewModel.heading != nil }

        #expect(labelInvalidated.isRaised)
        #expect(viewModel.spokenLabel(for: viewModel.suggestions[0], at: 0) == "Clough Commons, 350 feet, slightly left")
    }

    @Test func destinationSearchViewModelSpeaksDistanceAndDirection() async {
        let locationProvider = ControllableLocationProvider()
        let settings = DistanceSettings()
        settings.units = .metres

        let target = coordinate(distanceMetres: 120, bearingDegrees: 180)
        let searchService = StubDestinationSearch(suggestions: [
            SearchSuggestion(title: "Tech Tower", subtitle: "225 North Ave", coordinate: target)
        ])
        let viewModel = DestinationSearchViewModel(
            search: searchService,
            location: locationProvider,
            distances: settings,
            now: { sampleTime + 1 }
        )

        let task = Task { await viewModel.start() }
        defer { task.cancel() }

        viewModel.query = "Tech"
        viewModel.queryChanged()
        locationProvider.yieldLocation(LocationSample(
            coordinate: origin,
            horizontalAccuracy: 5,
            timestamp: sampleTime
        ))
        await waitUntil { !viewModel.suggestions.isEmpty && viewModel.location != nil }

        #expect(viewModel.spokenLabel(for: viewModel.suggestions[0], at: 0) == "Tech Tower, 120 metres, south, 225 North Ave")
    }

    @Test func staleFixDropsDistanceAndStaleHeadingFallsBackToCompassPoints() async {
        let locationProvider = ControllableLocationProvider()
        var services = AppServices.preview
        services.location = locationProvider
        services.distanceSettings.units = .feet
        var time = sampleTime + 1

        let target = coordinate(distanceMetres: 106.7, bearingDegrees: 45)
        let searchService = StubDestinationSearch(suggestions: [
            SearchSuggestion(title: "Clough Commons", subtitle: "", coordinate: target)
        ])
        let viewModel = PlaceSearchViewModel(services: services, search: searchService, now: { time })

        let task = Task { await viewModel.start() }
        defer { task.cancel() }

        viewModel.query = "Clough"
        viewModel.search()
        let label = { viewModel.spokenLabel(for: viewModel.suggestions[0], at: 0) }

        await waitUntil { !viewModel.suggestions.isEmpty }
        #expect(label() == "Clough Commons")

        locationProvider.yieldAuthorization(.authorized(preciseAccuracy: true))
        locationProvider.yieldLocation(LocationSample(coordinate: origin, horizontalAccuracy: 5, timestamp: sampleTime))
        locationProvider.yieldHeading(HeadingSample(
            trueHeading: 90, magneticHeading: 92, accuracy: 10, timestamp: sampleTime
        ))
        await waitUntil { viewModel.location != nil && viewModel.heading != nil }
        #expect(label() == "Clough Commons, 350 feet, slightly left")

        time = sampleTime + HeadingEstimator.maximumSampleAge + 1
        #expect(label() == "Clough Commons, 350 feet, northeast")

        time = sampleTime + SearchResultSpeech.maximumFixAge + 1
        #expect(label() == "Clough Commons")
    }

    @Test func destinationSearchDropsDistanceAndDirectionFromAStaleFix() async {
        let locationProvider = ControllableLocationProvider()
        let settings = DistanceSettings()
        settings.units = .metres
        var time = sampleTime + 1

        let target = coordinate(distanceMetres: 120, bearingDegrees: 180)
        let searchService = StubDestinationSearch(suggestions: [
            SearchSuggestion(title: "Tech Tower", subtitle: "225 North Ave", coordinate: target)
        ])
        let viewModel = DestinationSearchViewModel(
            search: searchService, location: locationProvider, distances: settings, now: { time }
        )

        let task = Task { await viewModel.start() }
        defer { task.cancel() }

        viewModel.query = "Tech"
        viewModel.queryChanged()
        locationProvider.yieldLocation(LocationSample(coordinate: origin, horizontalAccuracy: 5, timestamp: sampleTime))
        await waitUntil { !viewModel.suggestions.isEmpty && viewModel.location != nil }
        #expect(viewModel.spokenLabel(for: viewModel.suggestions[0], at: 0) == "Tech Tower, 120 metres, south, 225 North Ave")

        time = sampleTime + SearchResultSpeech.maximumFixAge + 1
        #expect(viewModel.spokenLabel(for: viewModel.suggestions[0], at: 0) == "Tech Tower, 225 North Ave")
    }
}

/// Set from an observation's `onChange`, which may run off the main actor.
private final class Flag: Sendable {
    private let raised = Mutex(false)
    var isRaised: Bool { raised.withLock { $0 } }
    func raise() { raised.withLock { $0 = true } }
}

@MainActor
private final class StubMapKitAutocompleter: MapKitAutocompleting {
    var onResults: (([SearchSuggestion]) -> Void)?
    var onError: ((DestinationSearchError) -> Void)?
    var coordinatesByID: [SearchSuggestion.ID: GeoCoordinate] = [:]
    private(set) var coordinateLookups: [SearchSuggestion] = []

    func update(fragment: String) {}
    func cancel() {}

    func resolve(_ suggestion: SearchSuggestion) async throws -> Destination {
        throw DestinationSearchError.noMatch
    }

    func coordinate(for suggestion: SearchSuggestion) async -> GeoCoordinate? {
        coordinateLookups.append(suggestion)
        return coordinatesByID[suggestion.id]
    }
}

private final class StubDestinationSearch: DestinationSearching, @unchecked Sendable {
    private let results = Broadcaster<Result<[SearchSuggestion], DestinationSearchError>>(replaysLatest: true)
    private let items: [SearchSuggestion]

    init(suggestions: [SearchSuggestion]) {
        items = suggestions
    }

    func suggestions() -> AsyncStream<Result<[SearchSuggestion], DestinationSearchError>> {
        results.stream()
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results.send(.success(trimmed.isEmpty ? [] : items))
    }

    func resolve(_ suggestion: SearchSuggestion) async throws -> Destination {
        throw DestinationSearchError.noMatch
    }
}

private final class ControllableLocationProvider: LocationProvider, @unchecked Sendable {
    private let locations = Broadcaster<LocationSample>(replaysLatest: true)
    private let headings = Broadcaster<HeadingSample>(replaysLatest: true)
    private let authorizations = Broadcaster<LocationAuthorization>(replaysLatest: true)

    func locationSamples() -> AsyncStream<LocationSample> { locations.stream() }
    func headingSamples() -> AsyncStream<HeadingSample> { headings.stream() }
    func authorizationStates() -> AsyncStream<LocationAuthorization> { authorizations.stream() }
    func requestAuthorization() async {}

    func yieldLocation(_ sample: LocationSample) { locations.send(sample) }
    func yieldHeading(_ sample: HeadingSample) { headings.send(sample) }
    func yieldAuthorization(_ auth: LocationAuthorization) { authorizations.send(auth) }
}
