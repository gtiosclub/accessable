import Foundation
import Observation
import os

private let log = Logger(subsystem: "AccessAble", category: "Search")

@MainActor
@Observable
final class DestinationSearchViewModel {
    var query = ""
    private(set) var suggestions: [SearchSuggestion] = []
    private(set) var selectedDestination: Destination?

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var selectionTask: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
    }

    func start() async {
        for await suggestions in services.destinationSearch.suggestions() {
            self.suggestions = suggestions
        }
    }

    func queryChanged() {
        selectionTask?.cancel()
        selectedDestination = nil
        services.destinationSearch.update(query: query)
    }

    // cancels any in-flight lookup so a stale result can't overwrite a newer pick
    func select(_ suggestion: SearchSuggestion) {
        selectionTask?.cancel()
        selectionTask = Task {
            do {
                let destination = try await services.destinationSearch.resolve(suggestion)
                guard !Task.isCancelled else { return }
                selectedDestination = destination
            } catch {
                guard !Task.isCancelled else { return }
                log.error("Resolving suggestion failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
