import Foundation
import Observation

@MainActor
@Observable
final class DestinationSearchViewModel {
    var query = ""

    @ObservationIgnored private let autocompleter = DestinationAutocompleter()

    var suggestions: [SearchSuggestion] { autocompleter.suggestions }

    func queryChanged() {
        autocompleter.update(query: query)
    }
}
