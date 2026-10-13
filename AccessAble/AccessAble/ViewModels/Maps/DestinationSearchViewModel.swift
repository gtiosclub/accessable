import Foundation
import Observation
import os

private let log = Logger(subsystem: "AccessAble", category: "Search")

enum SearchProblem: Equatable {
    case suggestionsUnavailable
    case lookupFailed(SearchSuggestion)
}

@MainActor
@Observable
final class DestinationSearchViewModel {
    var query = ""
    private(set) var suggestions: [SearchSuggestion] = []
    private(set) var selectedSuggestionID: SearchSuggestion.ID?
    private(set) var selectedDestination: Destination?
    private(set) var isSearching = false
    private(set) var isResolving = false
    private(set) var problem: SearchProblem?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var lastSearchedQuery = ""

    init(services: AppServices) {
        self.services = services
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var showsNoResults: Bool {
        !trimmedQuery.isEmpty && !isSearching && problem == nil && suggestions.isEmpty
    }

    func start() async {
        for await result in services.destinationSearch.suggestions() {
            isSearching = false
            switch result {
            case .success(let suggestions):
                self.suggestions = suggestions
                if problem == .suggestionsUnavailable { problem = nil }
            case .failure:
                suggestions = []
                problem = .suggestionsUnavailable
            }
        }
    }

    func queryChanged() {
        // whitespace-only edits don't change the search, and MapKit never calls back for a repeat fragment
        guard trimmedQuery != lastSearchedQuery else { return }
        lastSearchedQuery = trimmedQuery
        selectionTask?.cancel()
        selectedSuggestionID = nil
        selectedDestination = nil
        isResolving = false
        problem = nil
        isSearching = !trimmedQuery.isEmpty
        services.destinationSearch.update(query: query)
    }

    // cancels any in-flight lookup so a stale result can't overwrite a newer pick
    func select(_ suggestion: SearchSuggestion) {
        selectionTask?.cancel()
        selectedSuggestionID = suggestion.id
        selectedDestination = nil
        isResolving = true
        problem = nil
        selectionTask = Task {
            do {
                let destination = try await services.destinationSearch.resolve(suggestion)
                guard !Task.isCancelled else { return }
                selectedDestination = destination
            } catch {
                guard !Task.isCancelled else { return }
                log.error("Resolving suggestion failed: \(error.localizedDescription, privacy: .public)")
                selectedSuggestionID = nil
                problem = .lookupFailed(suggestion)
            }
            isResolving = false
        }
    }
}
