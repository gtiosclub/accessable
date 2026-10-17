import MapKit
import os

private let log = Logger(subsystem: "AccessAble", category: "Search")

@MainActor
final class DestinationAutocompleter: NSObject, DestinationSearching {
    private let results = Broadcaster<Result<[SearchSuggestion], DestinationSearchError>>()
    private let completer = MKLocalSearchCompleter()
    private var completions: [SearchSuggestion.ID: MKLocalSearchCompletion] = [:]
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

    func suggestions() -> AsyncStream<Result<[SearchSuggestion], DestinationSearchError>> {
        results.stream()
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completer.cancel()
            setResults([])
            return
        }
        completer.queryFragment = trimmed
    }

    func resolve(_ suggestion: SearchSuggestion) async throws -> Destination {
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
        return Destination(mapItem: place, fallbackName: suggestion.title)
    }

    // dedupes results and keeps each completion for resolve
    private func setResults(_ newResults: [MKLocalSearchCompletion]) {
        var completions: [SearchSuggestion.ID: MKLocalSearchCompletion] = [:]
        let suggestions = newResults.compactMap { result -> SearchSuggestion? in
            let suggestion = SearchSuggestion(title: result.title, subtitle: result.subtitle)
            guard completions[suggestion.id] == nil else { return nil }
            completions[suggestion.id] = result
            return suggestion
        }
        self.completions = completions
        results.send(.success(suggestions))
    }
}

extension DestinationAutocompleter: MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        setResults(completer.results)
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        // MapKit reports "nothing matched" as an error; show it as an empty list instead
        if (error as? MKError)?.code == .placemarkNotFound {
            setResults([])
            return
        }
        log.error("Autocomplete failed: \(error.localizedDescription, privacy: .public)")
        completions = [:]
        results.send(.failure(.suggestionsUnavailable))
    }
}
