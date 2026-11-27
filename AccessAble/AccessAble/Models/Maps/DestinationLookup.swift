import Foundation
import MapKit

/// Result of looking up a spoken place name for voice "take me to…".
enum DestinationLookupResult: Equatable, Sendable {
    case one(Destination)
    case several([Destination])
    case none
}

/// Campus nicknames for voice destination lookup. `CampusNicknameDictionary` conforms.
protocol NicknameDestinationSource: Sendable {
    func destinations(matching query: String) -> [Destination]
}

/// Saved places for voice destination lookup.
protocol SavedDestinationSource: Sendable {
    func destinations(matching query: String) async -> [Destination]
}

/// One-shot MapKit place search for voice destination lookup.
protocol MapDestinationSource: Sendable {
    func destinations(matching query: String) async -> [Destination]
}

extension CampusNicknameDictionary: NicknameDestinationSource {
    func destinations(matching query: String) -> [Destination] {
        matches(for: query).map(\.destination)
    }
}

/// Adapts `SavedPlacesStore` (main actor) for `DestinationLookup`.
struct SavedPlacesDestinationSource: SavedDestinationSource {
    private let matching: @Sendable (String) async -> [Destination]

    @MainActor
    init(store: SavedPlacesStore) {
        matching = { query in
            await MainActor.run { store.matching(query: query).map(\.destination) }
        }
    }

    init(matching: @escaping @Sendable (String) async -> [Destination]) {
        self.matching = matching
    }

    func destinations(matching query: String) async -> [Destination] {
        await matching(query)
    }
}

/// `MKLocalSearch` natural-language query around a region.
struct MapKitDestinationSource: MapDestinationSource {
    var region: SearchRegion

    func destinations(matching query: String) async -> [Destination] {
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
            return response.mapItems.prefix(3).map {
                Destination(mapItem: $0, fallbackName: trimmed)
            }
        } catch {
            return []
        }
    }
}

/// Looks up a spoken place name: nicknames, then saved places, then MapKit.
struct DestinationLookup: Sendable {
    var nicknames: any NicknameDestinationSource
    var saved: any SavedDestinationSource
    var mapKit: any MapDestinationSource

    static let maxSpoken = 3

    func lookUp(_ spokenName: String) async -> DestinationLookupResult {
        let trimmed = spokenName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        let fromNicknames = nicknames.destinations(matching: trimmed)
        if let result = Self.classify(fromNicknames) { return result }

        let fromSaved = await saved.destinations(matching: trimmed)
        if let result = Self.classify(fromSaved) { return result }

        return Self.classify(await mapKit.destinations(matching: trimmed)) ?? .none
    }

    private static func classify(_ destinations: [Destination]) -> DestinationLookupResult? {
        switch destinations.count {
        case 0: nil
        case 1: .one(destinations[0])
        default: .several(Array(destinations.prefix(maxSpoken)))
        }
    }
}
