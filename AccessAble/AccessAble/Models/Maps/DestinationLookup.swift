import Foundation
import MapKit

/// Result of looking up a spoken place name for voice "take me to…".
enum DestinationLookupResult: Equatable, Sendable {
    case one(Destination)
    case several([Destination])
    case none
}

/// A place a source found, with the names it can be called by (nicknames, a saved label).
struct DestinationCandidate: Equatable, Sendable {
    var destination: Destination
    var names: [String]

    init(_ destination: Destination, names: [String]? = nil) {
        self.destination = destination
        self.names = names ?? [destination.name]
    }
}

/// The place search couldn't run; distinct from finding nothing.
enum PlaceLookupError: Error, Equatable {
    /// No network, or the server couldn't be reached.
    case offline
    case failed
}

/// Campus nicknames for voice destination lookup. `CampusNicknameDictionary` conforms.
protocol NicknameDestinationSource: Sendable {
    func destinations(matching query: String) -> [DestinationCandidate]
}

/// Saved places for voice destination lookup.
protocol SavedDestinationSource: Sendable {
    func destinations(matching query: String) async -> [DestinationCandidate]
}

/// One-shot MapKit place search for voice destination lookup. Throws `PlaceLookupError`
/// or `CancellationError` when the search couldn't run; an empty result means nothing was found.
protocol MapDestinationSource: Sendable {
    func destinations(matching query: String) async throws -> [DestinationCandidate]
}

extension CampusNicknameDictionary: NicknameDestinationSource {
    func destinations(matching query: String) -> [DestinationCandidate] {
        matches(for: query).map { DestinationCandidate($0.destination, names: $0.allNames) }
    }
}

/// Adapts `SavedPlacesStore` (main actor) for `DestinationLookup`.
struct SavedPlacesDestinationSource: SavedDestinationSource {
    private let store: SavedPlacesStore

    init(store: SavedPlacesStore) {
        self.store = store
    }

    func destinations(matching query: String) async -> [DestinationCandidate] {
        await MainActor.run {
            store.matching(query: query).map { place in
                DestinationCandidate(place.destination, names: [place.label, place.name].compactMap(\.self))
            }
        }
    }
}

/// `MKLocalSearch` natural-language query around a region.
struct MapKitDestinationSource: MapDestinationSource {
    var region: SearchRegion

    func destinations(matching query: String) async throws -> [DestinationCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = [.address, .pointOfInterest]
        request.region = MKCoordinateRegion(
            center: region.center.clCoordinate,
            latitudinalMeters: region.radius * 2,
            longitudinalMeters: region.radius * 2
        )
        request.regionPriority = .required
        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.map {
                DestinationCandidate(Destination(mapItem: $0, fallbackName: trimmed))
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? MKError, error.code == .placemarkNotFound { return [] }
            throw Self.searchError(error)
        }
    }

    private static func searchError(_ error: any Error) -> PlaceLookupError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return .offline }
        if let error = error as? MKError, error.code == .serverFailure || error.code == .loadingThrottled {
            return .offline
        }
        return .failed
    }
}

/// Looks up a spoken place name: nicknames, then saved places, then MapKit.
struct DestinationLookup: Sendable {
    var nicknames: any NicknameDestinationSource
    var saved: any SavedDestinationSource
    var mapKit: any MapDestinationSource

    static let maxSpoken = 3

    /// - Throws: What the MapKit source throws when the search couldn't run.
    func lookUp(_ spokenName: String) async throws -> DestinationLookupResult {
        let trimmed = spokenName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        if let result = Self.classify(nicknames.destinations(matching: trimmed), for: trimmed) { return result }
        if let result = Self.classify(await saved.destinations(matching: trimmed), for: trimmed) { return result }
        return Self.classify(try await mapKit.destinations(matching: trimmed), for: trimmed) ?? .none
    }

    /// The saved place labelled (or named) Home, if there is one.
    func home() async -> Destination? {
        let home = Self.normalized("Home")
        return await saved.destinations(matching: "Home")
            .first { $0.names.contains { Self.normalized($0) == home } }?
            .destination
    }

    /// One exact name match wins outright; otherwise exact, then prefix, then other matches.
    private static func classify(_ candidates: [DestinationCandidate], for query: String) -> DestinationLookupResult? {
        guard !candidates.isEmpty else { return nil }
        let spoken = normalized(query)
        let ranked = candidates.enumerated()
            .map { (rank: rank(of: $0.element, for: spoken), index: $0.offset, destination: $0.element.destination) }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
        if ranked.count == 1 || (ranked[0].rank == 0 && ranked[1].rank != 0) {
            return .one(ranked[0].destination)
        }
        return .several(ranked.prefix(maxSpoken).map(\.destination))
    }

    /// 0 for an exact name, 1 for a name starting with what was said, 2 for anything else.
    private static func rank(of candidate: DestinationCandidate, for spoken: String) -> Int {
        let names = candidate.names.map(normalized)
        if names.contains(spoken) { return 0 }
        if names.contains(where: { $0.hasPrefix(spoken) }) { return 1 }
        return 2
    }

    /// Lowercased, without accents or punctuation, single-spaced.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) })
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
