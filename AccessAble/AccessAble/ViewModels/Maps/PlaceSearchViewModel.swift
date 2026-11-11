import CoreLocation
import Foundation
import MapKit
import Observation

/// Where a trip is planned from. A live trip always starts where the user really is; another
/// place is for looking at the directions from there.
enum SearchOrigin: Hashable, Sendable {
    case myLocation
    case place(SamplePlace)

    /// The place, or nil for My Location.
    var place: SamplePlace? {
        if case .place(let place) = self { place } else { nil }
    }
}

/// Owner: Maps (2.x). State for Search Destination: the From / To fields, live results,
/// category searches, distances from the user's real location, and dictation into either field.
///
/// The To field searches real places through `DestinationSearchViewModel` (MapKit
/// autocomplete biased to campus), which owns the results, "no results", errors, the spoken
/// count and resolving a pick into a `Destination`. Typing is debounced, so results settle
/// once the user pauses rather than jumping on every letter, and `isSearching` says when they
/// are about to change. The From field and saved places still search `SampleContent`.
@MainActor
@Observable
final class PlaceSearchViewModel {
    enum Field: Hashable { case origin, destination }

    var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    var originQuery = "" {
        didSet { if originQuery != oldValue { scheduleSearch() } }
    }
    var category: PlaceCategory? {
        didSet { if category != oldValue { search() } }
    }
    private(set) var origin: SearchOrigin = .myLocation

    /// What the results reflect: the text as of the last pause in typing.
    private(set) var settledQuery = ""
    private(set) var settledOriginQuery = ""
    /// Typing hasn't paused yet.
    private(set) var isSettling = false

    /// The real search behind the To field.
    let destinationSearch: DestinationSearchViewModel

    private(set) var location: LocationSample?
    private(set) var authorization: LocationAuthorization = .notDetermined
    /// The street the user is on, from reverse geocoding: "Ferst Dr NW".
    private(set) var locationName: String?

    let dictation = SpeechDictation()
    private(set) var dictatingField: Field?

    /// Pause in typing before results update.
    static let debounce: Duration = .milliseconds(150)
    /// A new street name is looked up after moving this far, in metres.
    static let renameDistance: Double = 30

    @ObservationIgnored private let services: AppServices?
    @ObservationIgnored private let places: [SamplePlace]
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var namedAt: GeoCoordinate?

    /// `search` overrides `services.destinationSearch`; without either it searches a few
    /// sample places, for previews and tests.
    init(
        services: AppServices? = nil,
        search: (any DestinationSearching)? = nil,
        places: [SamplePlace] = SampleContent.places
    ) {
        self.services = services
        self.places = places
        destinationSearch = DestinationSearchViewModel(
            search: search ?? services?.destinationSearch ?? PlaceholderDestinationSearch()
        )
    }

    // MARK: - Results

    var isFiltering: Bool {
        !settledQuery.trimmingCharacters(in: .whitespaces).isEmpty || category != nil
    }

    /// Typing hasn't paused, or results for what was typed haven't arrived.
    var isSearching: Bool { isSettling || destinationSearch.isSearching }

    var suggestions: [SearchSuggestion] { destinationSearch.suggestions }
    var problem: SearchProblem? { destinationSearch.problem }
    var showsNoResults: Bool { isFiltering && !isSettling && destinationSearch.showsNoResults }

    /// The picked result once it has been looked up. Opening it is up to the view.
    var selectedDestination: Destination? { destinationSearch.selectedDestination }

    func isResolving(_ suggestion: SearchSuggestion) -> Bool {
        destinationSearch.isResolving && destinationSearch.selectedSuggestionID == suggestion.id
    }

    /// Looks up the picked result; `selectedDestination` is set when it is found.
    func select(_ suggestion: SearchSuggestion) {
        destinationSearch.select(suggestion)
    }

    /// What is sent to MapKit: the typed text, then the category ("Clough restaurants").
    var searchText: String {
        [settledQuery.trimmingCharacters(in: .whitespacesAndNewlines), category?.searchTerm]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// "3 results for Clough", "Searching…", or "No results" when suggestions can't load.
    var resultsSummary: String {
        if isSearching { return "Searching…" }
        if problem == .suggestionsUnavailable { return "No results" }
        if let announcement = destinationSearch.resultsAnnouncement { return announcement }
        // Once a result is picked the announcement goes quiet; the count still shows.
        let count = suggestions.count
        return count == 1 ? "1 result" : "\(count) results"
    }

    /// For the From field: matches for what was typed, or saved places when nothing was.
    var originResults: [SamplePlace] {
        let trimmed = settledOriginQuery.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return places.filter(\.isSaved) }
        return nearestFirst(Self.search(trimmed, category: nil, in: places))
    }

    /// Straight-line distance and an estimated walk, or nil without a location.
    func distanceText(to place: SamplePlace) -> String? {
        guard let metres = distance(to: place) else { return nil }
        return Self.distanceText(metres: metres)
    }

    static func distanceText(metres: Double) -> String {
        let distance = metres < 1000
            ? "\(max(10, Int((metres / 10).rounded()) * 10)) m"
            : (metres / 1000).formatted(.number.precision(.fractionLength(1))) + " km"
        // Straight line at a walking pace; the route is longer, so this says "about".
        let minutes = max(1, Int((metres / 1.2 / 60).rounded()))
        return "\(distance) · about \(minutes) min walk"
    }

    private func distance(to place: SamplePlace) -> Double? {
        guard let location else { return nil }
        return GeoMath.distance(
            from: location.coordinate,
            to: GeoCoordinate(latitude: place.latitude, longitude: place.longitude)
        )
    }

    private func nearestFirst(_ places: [SamplePlace]) -> [SamplePlace] {
        guard location != nil else { return places }
        return places.sorted { (distance(to: $0) ?? 0) < (distance(to: $1) ?? 0) }
    }

    /// Name, address or initials ("CULC") contain the query; the category matches if given.
    static func search(_ query: String, category: PlaceCategory?, in places: [SamplePlace]) -> [SamplePlace] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || category != nil else { return [] }
        return places.filter { place in
            let matchesQuery = trimmed.isEmpty
                || place.name.localizedStandardContains(trimmed)
                || place.address.localizedStandardContains(trimmed)
                || initials(of: place.name).localizedStandardContains(trimmed)
            return matchesQuery && (category.map { place.category == $0 } ?? true)
        }
    }

    /// The parts of `name` that matched `query`: the substring, or the first letters of the
    /// words when it matched by initials. Empty when nothing matched.
    static func matchedRanges(in name: String, for query: String) -> [Range<String.Index>] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let range = name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) {
            return [range]
        }
        // Initials: "CULC" lights up the C, U, L, C that start the words.
        let wordStarts = name.indices.filter { index in
            name[index].isLetter && (index == name.startIndex || name[name.index(before: index)] == " ")
        }
        let initials = String(wordStarts.map { name[$0] })
        guard let match = initials.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return []
        }
        let first = initials.distance(from: initials.startIndex, to: match.lowerBound)
        let count = initials.distance(from: match.lowerBound, to: match.upperBound)
        return wordStarts[first ..< first + count].map { $0 ..< name.index(after: $0) }
    }

    private static func initials(of name: String) -> String {
        String(name.split(separator: " ").compactMap(\.first))
    }

    // MARK: - Typing

    private func scheduleSearch() {
        searchTask?.cancel()
        isSettling = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.search()
        }
    }

    /// Settles the results on what is typed now.
    func search() {
        searchTask?.cancel()
        settledQuery = query
        settledOriginQuery = originQuery
        isSettling = false
        destinationSearch.query = searchText
        destinationSearch.queryChanged()
    }

    func clearFilters() {
        query = ""
        category = nil
        search()
    }

    // MARK: - From

    func chooseOrigin(_ origin: SearchOrigin) {
        self.origin = origin
        originQuery = ""
        search()
    }

    /// Swaps From and To when From is a place: "from the library to …" becomes a search for
    /// the library from My Location. A trip can't end where the user already is, so My
    /// Location never becomes the destination.
    var canSwap: Bool { origin.place != nil }

    func swap() {
        guard let place = origin.place else { return }
        origin = .myLocation
        query = place.name
        search()
    }

    // MARK: - Location

    /// Listens for search results, follows the user's location and names the street.
    /// Returns when cancelled.
    func start() async {
        let destinationSearch = destinationSearch
        guard let services else {
            await destinationSearch.start()
            return
        }
        await services.location.requestAuthorization()
        await withDiscardingTaskGroup { group in
            group.addTask { await destinationSearch.start() }
            group.addTask {
                for await authorization in services.location.authorizationStates() {
                    await self.receive(authorization)
                }
            }
            group.addTask {
                for await sample in services.location.locationSamples() {
                    await self.receive(sample)
                }
            }
        }
    }

    private func receive(_ authorization: LocationAuthorization) {
        self.authorization = authorization
    }

    private func receive(_ sample: LocationSample) {
        // A fix this rough would put the user in the wrong building.
        guard sample.horizontalAccuracy <= 100 else { return }
        location = sample
        if let namedAt, GeoMath.distance(from: namedAt, to: sample.coordinate) < Self.renameDistance { return }
        namedAt = sample.coordinate
        Task { await self.name(sample.coordinate) }
    }

    private func name(_ coordinate: GeoCoordinate) async {
        if let name = await Self.streetName(at: coordinate) { locationName = name }
    }

    /// Off the main actor: MapKit's request and results aren't Sendable, a String is.
    @concurrent private nonisolated static func streetName(at coordinate: GeoCoordinate) async -> String? {
        guard let request = MKReverseGeocodingRequest(
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        ), let item = try? await request.mapItems.first else { return nil }
        return item.address?.shortAddress ?? item.name
    }

    /// "Ferst Dr NW · ±8 m", "Finding you…", or why it can't.
    var locationDetail: String {
        switch authorization {
        case .denied, .restricted: return "Location is off. Turn it on in Settings."
        case .notDetermined: return "Allow location to start from here"
        case .authorized: break
        }
        guard let location else { return "Finding you…" }
        let accuracy = "±\(Int(location.horizontalAccuracy.rounded())) m"
        return [locationName, accuracy].compactMap(\.self).joined(separator: " · ")
    }

    var isLocationOff: Bool {
        authorization == .denied || authorization == .restricted
    }

    // MARK: - Dictation

    /// Starts dictating into `field`, or stops if it is already listening there.
    func toggleDictation(into field: Field) async {
        if dictation.isRecording {
            let wasField = dictatingField
            dictation.stop()
            dictatingField = nil
            if wasField == field { return }
        }
        dictatingField = field
        dictation.onTranscript = { [weak self] text, isFinal in
            guard let self else { return }
            switch field {
            case .origin: originQuery = text
            case .destination: query = text
            }
            if isFinal {
                dictatingField = nil
                search()
            }
        }
        dictation.onError = { [weak self] _ in self?.dictatingField = nil }
        await dictation.start()
        if !dictation.isRecording { dictatingField = nil }
    }

    func stop() {
        searchTask?.cancel()
        dictation.cancel()
        dictatingField = nil
    }
}
