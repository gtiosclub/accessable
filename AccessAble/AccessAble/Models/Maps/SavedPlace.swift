import CoreLocation
import Foundation
import Observation

/// A place saved by the user on-device, with an optional label such as "Home" or "Class".
struct SavedPlace: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var address: String?
    var coordinate: GeoCoordinate
    var label: String?
    var category: PlaceCategory
    var savedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        address: String? = nil,
        coordinate: GeoCoordinate,
        label: String? = nil,
        category: PlaceCategory = .labeledPlaces,
        savedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.address = Self.normalizedText(address)
        self.coordinate = coordinate
        self.label = Self.normalizedLabel(label, placeName: name)
        self.category = category
        self.savedAt = savedAt
    }

    /// Primary title shown to the user: the custom label when set, otherwise the place name.
    var displayName: String {
        Self.normalizedLabel(label, placeName: name) ?? name
    }

    /// Secondary line: the underlying place name when a custom label is set, otherwise the address.
    var subtitle: String? {
        if Self.normalizedLabel(label, placeName: name) != nil {
            return name
        }
        return Self.normalizedText(address)
    }

    /// Address shown beneath the place name when a custom label is already shown.
    var detailAddress: String? {
        guard Self.normalizedLabel(label, placeName: name) != nil else { return nil }
        return Self.normalizedText(address)
    }

    var destination: Destination {
        Destination(name: name, coordinate: coordinate, address: address)
    }

    var clCoordinate: CLLocationCoordinate2D {
        coordinate.clCoordinate
    }

    /// Spoken summary for VoiceOver, including custom label, place name, and address when present.
    var accessibilitySummary: String {
        var parts = [displayName]
        if let subtitle { parts.append(subtitle) }
        if let detailAddress { parts.append(detailAddress) }
        return parts.joined(separator: ", ")
    }

    /// Converts to `SamplePlace` so existing route picker, origin, and trip flows keep working.
    func asSamplePlace() -> SamplePlace {
        SamplePlace(
            id: "saved:\(id.uuidString)",
            name: name,
            address: address ?? "",
            category: category,
            rating: 0,
            reviewCount: 0,
            recordedRouteCount: 0,
            isSaved: true,
            isRecent: false,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            label: Self.normalizedLabel(label, placeName: name)
        )
    }

    /// Matches the same real-world place across search results and details views.
    func matches(destination: Destination) -> Bool {
        name.caseInsensitiveCompare(destination.name) == .orderedSame
            && GeoMath.distance(from: coordinate, to: destination.coordinate) < 15
    }

    func matches(query: String, category: PlaceCategory? = nil) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchesCategory = category.map { self.category == $0 } ?? true
        guard !trimmed.isEmpty else { return category != nil && matchesCategory }
        let matchesText =
            (label?.localizedStandardContains(trimmed) ?? false)
            || name.localizedStandardContains(trimmed)
            || (address?.localizedStandardContains(trimmed) ?? false)
            || Self.initials(of: name).localizedStandardContains(trimmed)
            || (label.map { Self.initials(of: $0).localizedStandardContains(trimmed) } ?? false)
        return matchesText && matchesCategory
    }

    static func normalizedText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedLabel(_ raw: String?, placeName: String? = nil) -> String? {
        guard let clean = normalizedText(raw) else { return nil }
        if let placeName, clean == placeName { return nil }
        return clean
    }

    private static func initials(of text: String) -> String {
        String(text.split(separator: " ").compactMap(\.first))
    }
}

/// Persists user-saved places in `UserDefaults` and keeps UI screens in sync.
@MainActor
@Observable
final class SavedPlacesStore {
    private(set) var places: [SavedPlace]

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let storageKey: String

    init(defaults: UserDefaults, storageKey: String = "savedPlaces") {
        self.defaults = defaults
        self.storageKey = storageKey
        self.places = Self.load(from: defaults, key: storageKey)
    }

    /// In-memory store for isolated tests and SwiftUI previews.
    init(places: [SavedPlace] = []) {
        self.defaults = nil
        self.storageKey = "savedPlaces"
        self.places = places
    }

    @discardableResult
    func save(
        destination: Destination,
        label: String? = nil,
        category: PlaceCategory = .labeledPlaces
    ) -> SavedPlace {
        let cleanLabel = SavedPlace.normalizedLabel(label, placeName: destination.name)
        if let index = places.firstIndex(where: { $0.matches(destination: destination) }) {
            if cleanLabel != nil {
                places[index].label = cleanLabel
            }
            persist()
            return places[index]
        }
        let saved = SavedPlace(
            name: destination.name,
            address: destination.address,
            coordinate: destination.coordinate,
            label: cleanLabel,
            category: category
        )
        places.insert(saved, at: 0)
        persist()
        return saved
    }

    func rename(id: SavedPlace.ID, to rawName: String) {
        guard let index = places.firstIndex(where: { $0.id == id }) else { return }
        places[index].label = SavedPlace.normalizedLabel(rawName, placeName: places[index].name)
        persist()
    }

    func delete(id: SavedPlace.ID) {
        let before = places.count
        places.removeAll { $0.id == id }
        if places.count != before {
            persist()
        }
    }

    func savedPlace(id: SavedPlace.ID) -> SavedPlace? {
        places.first { $0.id == id }
    }

    func savedPlace(matching destination: Destination) -> SavedPlace? {
        places.first { $0.matches(destination: destination) }
    }

    func matching(query: String, category: PlaceCategory? = nil) -> [SavedPlace] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || category != nil else { return [] }
        return places.filter { $0.matches(query: trimmed, category: category) }
    }

    private func persist() {
        guard let defaults, let data = try? JSONEncoder().encode(places) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func load(from defaults: UserDefaults, key: String) -> [SavedPlace] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedPlace].self, from: data) else {
            return []
        }
        return decoded
    }
}
