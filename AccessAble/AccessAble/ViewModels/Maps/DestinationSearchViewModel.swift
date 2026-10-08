import MapKit
import Observation
import os

private let log = Logger(subsystem: "AccessAble", category: "Search")

@MainActor
@Observable
final class DestinationSearchViewModel {
    var query = ""
    private(set) var selectedPlace: MKMapItem?

    @ObservationIgnored private let autocompleter = DestinationAutocompleter()
    @ObservationIgnored private var selectionTask: Task<Void, Never>?

    var suggestions: [SearchSuggestion] { autocompleter.suggestions }

    func queryChanged() {
        autocompleter.update(query: query)
    }

    func select(_ suggestion: SearchSuggestion) {
        selectionTask?.cancel()
        selectionTask = Task {
            do {
                let place = try await autocompleter.resolve(suggestion)
                guard !Task.isCancelled else { return }
                selectedPlace = place
            } catch {
                guard !Task.isCancelled else { return }
                log.error("Resolving \(suggestion.title) failed: \(error.localizedDescription)")
            }
        }
    }
}
