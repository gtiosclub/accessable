import MapKit
import os

private let log = Logger(subsystem: "AccessAble", category: "Search")

@MainActor
final class DestinationAutocompleter: NSObject, DestinationSearching {
    private let results = Broadcaster<Result<[SearchSuggestion], DestinationSearchError>>()
    private let completer = MKLocalSearchCompleter()
    private var completions: [SearchSuggestion.ID: MKLocalSearchCompletion] = [:]

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
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
        let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
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
