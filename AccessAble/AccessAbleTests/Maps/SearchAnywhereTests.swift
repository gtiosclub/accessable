import Foundation
import MapKit
import Testing
@testable import AccessAble

@MainActor
private final class RecordingMapKit: MapKitAutocompleting {
    var onResults: (([SearchSuggestion]) -> Void)?
    var onError: ((DestinationSearchError) -> Void)?
    private(set) var regions: [SearchRegion] = []
    /// Each region MapKit is recentred on, in order, for tests that wait on a follow.
    let recentred: AsyncStream<SearchRegion>
    private let recentredContinuation: AsyncStream<SearchRegion>.Continuation

    init() {
        (recentred, recentredContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func update(fragment: String) {}
    func cancel() {}
    func resolve(_ suggestion: SearchSuggestion) async throws -> Destination {
        throw DestinationSearchError.noMatch
    }
    func setSearchRegion(_ region: SearchRegion) {
        regions.append(region)
        recentredContinuation.yield(region)
    }
}

/// Fixes and permission changes sent by the test; a new subscriber gets the latest of each.
private final class FakeLocation: LocationProvider, Sendable {
    private let locations = Broadcaster<LocationSample>(replaysLatest: true)
    private let authorizations = Broadcaster<LocationAuthorization>(replaysLatest: true)

    init(authorization: LocationAuthorization = .authorized(preciseAccuracy: true)) {
        authorizations.send(authorization)
    }

    func locationSamples() -> AsyncStream<LocationSample> { locations.stream(bufferingPolicy: .unbounded) }
    func headingSamples() -> AsyncStream<HeadingSample> { AsyncStream { $0.finish() } }
    func authorizationStates() -> AsyncStream<LocationAuthorization> { authorizations.stream() }
    func requestAuthorization() async {}

    func send(_ coordinate: GeoCoordinate) {
        locations.send(LocationSample(coordinate: coordinate, horizontalAccuracy: 5, timestamp: Date(timeIntervalSince1970: 0)))
    }

    func send(_ authorization: LocationAuthorization) {
        authorizations.send(authorization)
    }
}

@MainActor
struct SearchAnywhereTests {
    private let chicago = GeoCoordinate(latitude: 41.8789, longitude: -87.6359)
    private let nearby = GeoCoordinate(latitude: 41.883, longitude: -87.63)
    private let far = GeoCoordinate(latitude: 41.95, longitude: -87.7)
    /// About 10 km from campus: still close enough for campus nicknames.
    private let midtown = GeoCoordinate(latitude: 33.85, longitude: -84.36)

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
    func followRecentresAfterAKilometreAndFallsBackWhenPermissionIsRevoked() async {
        let mapKit = RecordingMapKit()
        let search = DestinationAutocompleter(dictionary: .bundled, mapKit: mapKit)
        let location = FakeLocation()
        var recentred = mapKit.recentred.makeAsyncIterator()
        let following = Task { await search.followLocation(location) }

        location.send(chicago)
        #expect(await recentred.next() == SearchRegion.around(chicago))

        // The small move is skipped, so the next recentre is the far one.
        location.send(nearby)
        location.send(far)
        #expect(await recentred.next() == SearchRegion.around(far))

        location.send(.denied)
        #expect(await recentred.next() == .georgiaTech)
        #expect(search.searchRegion == .georgiaTech)

        following.cancel()
        await following.value
        #expect(mapKit.regions == [SearchRegion.around(chicago), SearchRegion.around(far), .georgiaTech])
    }

    @Test
    func followStartsOnCampusInsteadOfAnEarlierSearchsCentre() async {
        let mapKit = RecordingMapKit()
        let search = DestinationAutocompleter(dictionary: .bundled, mapKit: mapKit)
        search.updateRegion(for: chicago)
        var recentred = mapKit.recentred.makeAsyncIterator()
        _ = await recentred.next()

        // No fix yet on this screen.
        let following = Task { await search.followLocation(FakeLocation()) }
        #expect(await recentred.next() == .georgiaTech)

        following.cancel()
        await following.value
    }

    @Test
    func supersededFollowCannotMoveTheRegion() async {
        let mapKit = RecordingMapKit()
        let search = DestinationAutocompleter(dictionary: .bundled, mapKit: mapKit)
        let stale = FakeLocation()
        let current = FakeLocation()
        var recentred = mapKit.recentred.makeAsyncIterator()

        let first = Task { await search.followLocation(stale) }
        stale.send(chicago)
        #expect(await recentred.next() == SearchRegion.around(chicago))

        let second = Task { await search.followLocation(current) }
        #expect(await recentred.next() == .georgiaTech)

        // The first follow is still subscribed but no longer in charge.
        stale.send(.denied)
        stale.send(far)
        current.send(midtown)
        #expect(await recentred.next() == SearchRegion.around(midtown))

        first.cancel()
        second.cancel()
        await first.value
        await second.value
        #expect(mapKit.regions == [SearchRegion.around(chicago), .georgiaTech, SearchRegion.around(midtown)])
    }

    @Test
    func campusNicknamesAreSkippedFarFromCampus() async throws {
        let mapKit = RecordingMapKit()
        let search = DestinationAutocompleter(dictionary: .bundled, mapKit: mapKit)
        search.updateRegion(for: chicago)
        var results = search.suggestions().makeAsyncIterator()

        search.update(query: "culc")
        let chicagoResults = [SearchSuggestion(title: "CULC Chicago", subtitle: "Chicago, IL")]
        mapKit.onResults?(chicagoResults)

        // Had the dictionary run, its campus match would have arrived first.
        #expect(try #require(await results.next()).get() == chicagoResults)
    }

    @Test
    func campusNicknamesStayFirstNearCampus() async throws {
        let mapKit = RecordingMapKit()
        let search = DestinationAutocompleter(dictionary: .bundled, mapKit: mapKit)
        search.updateRegion(for: midtown)
        var results = search.suggestions().makeAsyncIterator()

        search.update(query: "clough")

        let first = try #require(await results.next()).get()
        #expect(first.first?.title == "Clough Undergraduate Learning Commons")
    }

    @Test
    func liveCompleterPrefersButDoesNotRequireTheSearchRegion() {
        let live = LiveMapKitAutocompleter(region: .georgiaTech)
        #expect(live.completer.regionPriority == .default)

        live.setSearchRegion(.around(chicago))
        #expect(abs(live.completer.region.center.latitude - chicago.latitude) < 1e-9)
        #expect(abs(live.completer.region.center.longitude - chicago.longitude) < 1e-9)
        #expect(live.region.center.latitude == live.completer.region.center.latitude)
    }

    @Test
    func placeLookupPrefersButDoesNotRequireTheSearchRegion() {
        let live = LiveMapKitAutocompleter(region: .around(chicago))
        let request = MKLocalSearch.Request()
        request.regionPriority = .required

        LiveMapKitAutocompleter.configure(request, region: live.region)

        #expect(request.regionPriority == .default)
        #expect(abs(request.region.center.latitude - chicago.latitude) < 1e-9)
        #expect(abs(request.region.center.longitude - chicago.longitude) < 1e-9)
    }

    @Test
    func farResultIsSpokenInMiles() {
        let willisTower = SearchSuggestion(title: "Willis Tower", subtitle: "Chicago, IL", coordinate: chicago)

        let spoken = SearchResultSpeech.label(
            for: willisTower,
            at: 0,
            from: SearchRegion.georgiaTech.center,
            heading: nil,
            distances: .imperial
        )

        // About 590 miles from campus, never millions of feet.
        #expect(spoken.hasPrefix("Willis Tower, 5"))
        #expect(spoken.contains(" miles"))
        #expect(!spoken.contains("feet"))
    }
}
