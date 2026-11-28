import MapKit
import os

private let log = Logger(subsystem: "AccessAble", category: "Search")

@MainActor
protocol MapKitAutocompleting: AnyObject {
    var onResults: (([SearchSuggestion]) -> Void)? { get set }
    var onError: ((DestinationSearchError) -> Void)? { get set }
    func update(fragment: String)
    func cancel()
    func resolve(_ suggestion: SearchSuggestion) async throws -> Destination
    func coordinate(for suggestion: SearchSuggestion) async -> GeoCoordinate?
    /// Recentres MapKit's bias toward `region`.
    func setSearchRegion(_ region: SearchRegion)
}

extension MapKitAutocompleting {
    func coordinate(for suggestion: SearchSuggestion) async -> GeoCoordinate? { nil }
    func setSearchRegion(_ region: SearchRegion) {}
}

@MainActor
final class DestinationAutocompleter: DestinationSearching {
    /// Replays the latest results: a search screen stops listening while another screen covers
    /// it, and results that arrive in that gap would otherwise be lost.
    private let results = Broadcaster<Result<[SearchSuggestion], DestinationSearchError>>(replaysLatest: true)
    private let dictionary: CampusNicknameDictionary
    private let mapKit: any MapKitAutocompleting
    private var dictionaryMatches: [CampusNicknamePlace] = []
    private var dictionaryDestinations: [SearchSuggestion.ID: Destination] = [:]
    private var resolvedCoordinates: [SearchSuggestion.ID: GeoCoordinate] = [:]
    private var coordinateTask: Task<Void, Never>?
    private var followGeneration = 0
    private var resultsGeneration = 0
    /// MapKit bias centre; campus until a fix arrives, then the user (updated every ~1 km).
    private(set) var searchRegion: SearchRegion
    private var lastUserCenter: GeoCoordinate?

    convenience init(region: SearchRegion = .georgiaTech, dictionary: CampusNicknameDictionary = .bundled) {
        self.init(dictionary: dictionary, mapKit: LiveMapKitAutocompleter(region: region), region: region)
    }

    init(
        dictionary: CampusNicknameDictionary = .bundled,
        mapKit: any MapKitAutocompleting,
        region: SearchRegion = .georgiaTech
    ) {
        self.dictionary = dictionary
        self.mapKit = mapKit
        self.searchRegion = region

        mapKit.onResults = { [weak self] mapKitResults in
            self?.applyMapKitResults(mapKitResults)
        }
        mapKit.onError = { [weak self] error in
            self?.applyMapKitFailure(error)
        }
    }

    /// Centres MapKit on the user while a search screen runs this, and on campus without a fix or permission.
    /// Returns when cancelled; a later call supersedes an earlier one still running.
    func followLocation(_ location: any LocationProvider) async {
        followGeneration += 1
        let generation = followGeneration
        // A centre from an earlier search may be stale; campus until this one's first fix.
        updateRegion(for: nil)
        await withDiscardingTaskGroup { group in
            group.addTask {
                for await authorization in location.authorizationStates() {
                    if case .authorized = authorization { continue }
                    await self.followed(nil, generation: generation)
                }
            }
            group.addTask {
                for await sample in location.locationSamples() {
                    await self.followed(sample.coordinate, generation: generation)
                }
            }
        }
    }

    private func followed(_ coordinate: GeoCoordinate?, generation: Int) {
        guard !Task.isCancelled, generation == followGeneration else { return }
        updateRegion(for: coordinate)
    }

    /// Recentres when the user has moved about a kilometre, or restores campus when `coordinate` is nil.
    func updateRegion(for coordinate: GeoCoordinate?) {
        guard let coordinate else {
            guard searchRegion != .georgiaTech || lastUserCenter != nil else { return }
            lastUserCenter = nil
            searchRegion = .georgiaTech
            mapKit.setSearchRegion(.georgiaTech)
            return
        }
        if let last = lastUserCenter,
           GeoMath.distance(from: last, to: coordinate) < SearchRegion.recenterDistance {
            return
        }
        lastUserCenter = coordinate
        let next = SearchRegion.around(coordinate)
        searchRegion = next
        mapKit.setSearchRegion(next)
    }

    func suggestions() -> AsyncStream<Result<[SearchSuggestion], DestinationSearchError>> {
        results.stream()
    }

    func update(query: String) {
        coordinateTask?.cancel()
        coordinateTask = nil
        resultsGeneration += 1

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            mapKit.cancel()
            dictionaryMatches = []
            dictionaryDestinations = [:]
            resolvedCoordinates = [:]
            results.send(.success([]))
            return
        }

        // Check the campus nickname dictionary before querying MapKit. Far from campus its matches would
        // only crowd out local results.
        let matches = searchRegion.isNearCampus ? dictionary.matches(for: trimmed) : []
        dictionaryMatches = matches
        dictionaryDestinations = Dictionary(
            matches.map { ($0.suggestion.id, $0.destination) },
            uniquingKeysWith: { first, _ in first }
        )
        if !matches.isEmpty {
            results.send(.success(matches.map(\.suggestion)))
        }

        mapKit.update(fragment: trimmed)
    }

    func resolve(_ suggestion: SearchSuggestion) async throws -> Destination {
        if let destination = dictionaryDestinations[suggestion.id] {
            return destination
        }
        return try await mapKit.resolve(suggestion)
    }

    private func applyMapKitResults(_ mapKitResults: [SearchSuggestion]) {
        coordinateTask?.cancel()
        coordinateTask = nil
        resultsGeneration += 1
        let generation = resultsGeneration

        let enriched = mergedWithCachedCoordinates(mapKitResults)
        results.send(.success(enriched))

        let unresolvedTop = enriched.prefix(SearchResultSpeech.maxSpokenResults).filter { $0.coordinate == nil }
        guard !unresolvedTop.isEmpty else { return }

        // Cancelled when the results are replaced, so a replaced set never starts its lookups.
        coordinateTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let lookups = unresolvedTop.map { suggestion in
                (suggestion.id, Task { @MainActor [weak self] () -> GeoCoordinate? in
                    guard !Task.isCancelled else { return nil }
                    return await self?.mapKit.coordinate(for: suggestion)
                })
            }
            let resolved: [SearchSuggestion.ID: GeoCoordinate] = await withTaskCancellationHandler {
                var coords: [SearchSuggestion.ID: GeoCoordinate] = [:]
                for (id, task) in lookups {
                    if let coordinate = await task.value {
                        coords[id] = coordinate
                    }
                }
                return coords
            } onCancel: {
                for (_, task) in lookups { task.cancel() }
            }

            guard !Task.isCancelled, self.resultsGeneration == generation, !resolved.isEmpty else { return }
            for (id, coordinate) in resolved {
                self.resolvedCoordinates[id] = coordinate
            }
            // A coordinate can show a MapKit result to be a nickname match under another name.
            let updated = self.mergedWithCachedCoordinates(mapKitResults)
            if updated != enriched {
                self.results.send(.success(updated))
            }
        }
    }

    private func mergedWithCachedCoordinates(_ mapKitResults: [SearchSuggestion]) -> [SearchSuggestion] {
        dictionary.merge(matches: dictionaryMatches, mapKitResults: applyCachedCoordinates(to: mapKitResults))
    }

    private func applyCachedCoordinates(to suggestions: [SearchSuggestion]) -> [SearchSuggestion] {
        suggestions.map { suggestion in
            guard suggestion.coordinate == nil, let coordinate = resolvedCoordinates[suggestion.id] else {
                return suggestion
            }
            return SearchSuggestion(title: suggestion.title, subtitle: suggestion.subtitle, coordinate: coordinate)
        }
    }

    private func applyMapKitFailure(_ error: DestinationSearchError) {
        coordinateTask?.cancel()
        coordinateTask = nil
        resultsGeneration += 1

        if !dictionaryMatches.isEmpty {
            results.send(.success(dictionaryMatches.map(\.suggestion)))
            return
        }
        results.send(.failure(error))
    }
}

@MainActor
final class LiveMapKitAutocompleter: NSObject, MapKitAutocompleting, MKLocalSearchCompleterDelegate {
    var onResults: (([SearchSuggestion]) -> Void)?
    var onError: ((DestinationSearchError) -> Void)?

    /// Internal so tests can check its configuration.
    let completer = MKLocalSearchCompleter()
    private var completions: [SearchSuggestion.ID: MKLocalSearchCompletion] = [:]
    private var resolvedDestinations: [SearchSuggestion.ID: Destination] = [:]
    private(set) var region: MKCoordinateRegion

    init(region: SearchRegion) {
        // MKCoordinateRegion takes a full width/height, so double the radius
        self.region = Self.coordinateRegion(region)
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.region = self.region
        // Prefer nearby results but still return named places far away (Chicago, etc.).
        completer.regionPriority = .default
    }

    func setSearchRegion(_ region: SearchRegion) {
        self.region = Self.coordinateRegion(region)
        completer.region = self.region
    }

    /// Biases the place lookup toward `region` without dropping places outside it.
    static func configure(_ request: MKLocalSearch.Request, region: MKCoordinateRegion) {
        request.region = region
        request.regionPriority = .default
    }

    private static func coordinateRegion(_ region: SearchRegion) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: region.center.latitude, longitude: region.center.longitude),
            latitudinalMeters: region.radius * 2,
            longitudinalMeters: region.radius * 2
        )
    }

    func update(fragment: String) {
        completer.queryFragment = fragment
    }

    func cancel() {
        completer.cancel()
        completions = [:]
        resolvedDestinations = [:]
    }

    func resolve(_ suggestion: SearchSuggestion) async throws -> Destination {
        if let cached = resolvedDestinations[suggestion.id] {
            return cached
        }
        guard let completion = completions[suggestion.id] else {
            throw DestinationSearchError.staleSuggestion
        }
        let request = MKLocalSearch.Request(completion: completion)
        Self.configure(request, region: region)
        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch {
            let code = (error as NSError).code
            if (error as? MKError)?.code == .loadingThrottled {
                log.error("Place lookup throttled by MapKit (code \(code, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            } else {
                log.error("Place lookup failed (code \(code, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
        guard let place = response.mapItems.first else {
            throw DestinationSearchError.noMatch
        }
        let destination = Destination(mapItem: place, fallbackName: suggestion.title)
        resolvedDestinations[suggestion.id] = destination
        return destination
    }

    func coordinate(for suggestion: SearchSuggestion) async -> GeoCoordinate? {
        if let cached = resolvedDestinations[suggestion.id] {
            return cached.coordinate
        }
        do {
            return try await resolve(suggestion).coordinate
        } catch {
            // A replaced result set cancels its lookups; that isn't a failure.
            if !Task.isCancelled {
                log.error("No coordinate for a spoken result: \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    // dedupes results and keeps each completion for resolve
    private func deliver(_ newResults: [MKLocalSearchCompletion]) {
        var completions: [SearchSuggestion.ID: MKLocalSearchCompletion] = [:]
        let suggestions = newResults.compactMap { result -> SearchSuggestion? in
            let suggestion = SearchSuggestion(title: result.title, subtitle: result.subtitle)
            guard completions[suggestion.id] == nil else { return nil }
            completions[suggestion.id] = result
            return suggestion
        }
        self.completions = completions
        resolvedDestinations = resolvedDestinations.filter { completions[$0.key] != nil }
        onResults?(suggestions)
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        deliver(completer.results)
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        // MapKit reports "nothing matched" as an error; show it as an empty list instead
        if (error as? MKError)?.code == .placemarkNotFound {
            deliver([])
            return
        }
        log.error("Autocomplete failed: \(error.localizedDescription, privacy: .public)")
        completions = [:]
        onError?(.suggestionsUnavailable)
    }
}
