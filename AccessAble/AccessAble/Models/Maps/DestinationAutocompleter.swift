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
}

extension MapKitAutocompleting {
    func coordinate(for suggestion: SearchSuggestion) async -> GeoCoordinate? { nil }
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
    private var resultsGeneration = 0

    convenience init(region: SearchRegion, dictionary: CampusNicknameDictionary = .bundled) {
        self.init(dictionary: dictionary, mapKit: LiveMapKitAutocompleter(region: region))
    }

    init(dictionary: CampusNicknameDictionary = .bundled, mapKit: any MapKitAutocompleting) {
        self.dictionary = dictionary
        self.mapKit = mapKit

        mapKit.onResults = { [weak self] mapKitResults in
            self?.applyMapKitResults(mapKitResults)
        }
        mapKit.onError = { [weak self] error in
            self?.applyMapKitFailure(error)
        }
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

        // Check the campus nickname dictionary before querying MapKit.
        let matches = dictionary.matches(for: trimmed)
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

        coordinateTask = Task { [weak self] in
            guard let self else { return }
            let lookups = unresolvedTop.map { suggestion in
                (suggestion.id, Task { @MainActor [weak self] in
                    await self?.mapKit.coordinate(for: suggestion)
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
private final class LiveMapKitAutocompleter: NSObject, MapKitAutocompleting, MKLocalSearchCompleterDelegate {
    var onResults: (([SearchSuggestion]) -> Void)?
    var onError: ((DestinationSearchError) -> Void)?

    private let completer = MKLocalSearchCompleter()
    private var completions: [SearchSuggestion.ID: MKLocalSearchCompletion] = [:]
    private var resolvedDestinations: [SearchSuggestion.ID: Destination] = [:]
    private let region: MKCoordinateRegion

    init(region: SearchRegion) {
        // MKCoordinateRegion takes a full width/height, so double the radius
        self.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: region.center.latitude, longitude: region.center.longitude),
            latitudinalMeters: region.radius * 2,
            longitudinalMeters: region.radius * 2
        )
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.region = self.region
        completer.regionPriority = .required
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
        request.region = region
        request.regionPriority = .required
        let response = try await MKLocalSearch(request: request).start()
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
        return try? await resolve(suggestion).coordinate
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
