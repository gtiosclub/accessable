import MapKit
import Observation
import os

private let log = Logger(subsystem: "AccessAble", category: "Search")

struct SearchSuggestion: Identifiable {
    let title: String
    let subtitle: String

    var id: String { "\(title)\n\(subtitle)" }
}

enum DestinationSearchError: Error {
    case staleSuggestion
    case noMatch
}

@MainActor
@Observable
final class DestinationAutocompleter: NSObject {
    private(set) var suggestions: [SearchSuggestion] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private var completions: [SearchSuggestion.ID: MKLocalSearchCompletion] = [:]

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
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

    func resolve(_ suggestion: SearchSuggestion) async throws -> MKMapItem {
        guard let completion = completions[suggestion.id] else {
            throw DestinationSearchError.staleSuggestion
        }
        let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        guard let place = response.mapItems.first else {
            throw DestinationSearchError.noMatch
        }
        return place
    }

    private func setResults(_ results: [MKLocalSearchCompletion]) {
        var completions: [SearchSuggestion.ID: MKLocalSearchCompletion] = [:]
        suggestions = results.compactMap { result in
            let suggestion = SearchSuggestion(title: result.title, subtitle: result.subtitle)
            guard completions[suggestion.id] == nil else { return nil }
            completions[suggestion.id] = result
            return suggestion
        }
        self.completions = completions
    }
}

extension DestinationAutocompleter: MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        setResults(completer.results)
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        log.error("Autocomplete failed: \(error.localizedDescription)")
        setResults([])
    }
}
