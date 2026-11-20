import Foundation
import Observation
import os

private let log = Logger(subsystem: "AccessAble", category: "Search")

enum SearchProblem: Equatable {
    case suggestionsUnavailable
    case lookupFailed(SearchSuggestion)

    /// Shown on screen and spoken to VoiceOver.
    var message: String {
        switch self {
        case .suggestionsUnavailable:
            "Couldn't load suggestions. Check your connection and keep typing."
        case .lookupFailed(let suggestion):
            "Couldn't get details for \(suggestion.title)."
        }
    }
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
    private(set) var location: LocationSample?
    private(set) var heading: UserHeading?

    @ObservationIgnored private let search: any DestinationSearching
    @ObservationIgnored private let locationProvider: (any LocationProvider)?
    @ObservationIgnored private let distances: DistanceSettings?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var lastSearchedQuery = ""
    @ObservationIgnored private var headingEstimator = HeadingEstimator()
    @ObservationIgnored private var newestReadingTime: Date?

    convenience init(services: AppServices) {
        self.init(
            search: services.destinationSearch,
            location: services.location,
            distances: services.distanceSettings
        )
    }

    init(
        search: any DestinationSearching,
        location: (any LocationProvider)? = nil,
        distances: DistanceSettings? = nil
    ) {
        self.search = search
        locationProvider = location
        self.distances = distances
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var showsNoResults: Bool {
        !trimmedQuery.isEmpty && !isSearching && problem == nil && suggestions.isEmpty
    }

    var resultsAnnouncement: String? {
        guard !isSearching, problem == nil, selectedSuggestionID == nil, !trimmedQuery.isEmpty else { return nil }
        switch suggestions.count {
        case 0: return "No results for \(trimmedQuery)"
        case 1: return "1 result for \(trimmedQuery)"
        default: return "\(suggestions.count) results for \(trimmedQuery)"
        }
    }

    func spokenLabel(for suggestion: SearchSuggestion, at index: Int) -> String {
        SearchResultSpeech.label(
            for: suggestion,
            at: index,
            from: location?.coordinate,
            heading: heading,
            distances: distances?.formatter ?? DistanceSettings().formatter
        )
    }

    func start() async {
        guard let locationProvider else {
            await listenForSuggestions()
            return
        }
        await withDiscardingTaskGroup { group in
            group.addTask { await self.listenForSuggestions() }
            group.addTask {
                for await sample in locationProvider.locationSamples() {
                    await self.receive(sample)
                }
            }
            group.addTask {
                for await sample in locationProvider.headingSamples() {
                    await self.receive(sample)
                }
            }
        }
    }

    private func listenForSuggestions() async {
        for await result in search.suggestions() {
            isSearching = false
            // The service replays its latest results to a new listener, and they can be for an
            // earlier screen's search. Nothing typed means nothing to show.
            guard !trimmedQuery.isEmpty else {
                suggestions = []
                if problem == .suggestionsUnavailable { problem = nil }
                continue
            }
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

    private func receive(_ sample: LocationSample) {
        guard sample.horizontalAccuracy <= 100 else { return }
        location = sample
        headingEstimator.update(with: sample)
        updateHeading(readingTime: sample.timestamp)
    }

    private func receive(_ sample: HeadingSample) {
        headingEstimator.update(with: sample)
        updateHeading(readingTime: sample.timestamp)
    }

    private func updateHeading(readingTime: Date) {
        let now = max(newestReadingTime ?? readingTime, readingTime)
        newestReadingTime = now
        heading = headingEstimator.heading(at: now)
    }

    func queryChanged() {
        // whitespace-only edits don't change the search, and MapKit never calls back for a repeat fragment
        guard trimmedQuery != lastSearchedQuery else { return }
        lastSearchedQuery = trimmedQuery
        selectionTask?.cancel()
        selectedSuggestionID = nil
        selectedDestination = nil
        isResolving = false
        // an offline failure would just be re-set (and re-announced) on every keystroke; start() clears it on success
        if case .lookupFailed = problem { problem = nil }
        isSearching = !trimmedQuery.isEmpty
        search.update(query: query)
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
                let destination = try await search.resolve(suggestion)
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

    /// Drops a lookup still in flight, so it can't open a place after the user has left.
    func cancelSelection() {
        guard isResolving else { return }
        selectionTask?.cancel()
        selectedSuggestionID = nil
        isResolving = false
    }
}
