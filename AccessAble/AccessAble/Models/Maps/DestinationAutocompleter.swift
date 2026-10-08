import MapKit
import Observation
import os

private let log = Logger(subsystem: "AccessAble", category: "Search")

struct SearchSuggestion: Identifiable {
    let title: String
    let subtitle: String

    var id: String { "\(title)\n\(subtitle)" }
}

@MainActor
@Observable
final class DestinationAutocompleter: NSObject {
    private(set) var suggestions: [SearchSuggestion] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completer.cancel()
            suggestions = []
            return
        }
        completer.queryFragment = trimmed
    }
}

extension DestinationAutocompleter: MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        var seen = Set<SearchSuggestion.ID>()
        suggestions = completer.results
            .map { SearchSuggestion(title: $0.title, subtitle: $0.subtitle) }
            .filter { seen.insert($0.id).inserted }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        log.error("Autocomplete failed: \(error.localizedDescription)")
        suggestions = []
    }
}
