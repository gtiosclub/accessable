import CoreLocation
import Foundation
import Observation

/// A destination the user has started walking to, persisted locally up to 10 most recent places.
struct RecentPlace: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var address: String?
    var coordinate: GeoCoordinate
    var category: PlaceCategory
    var lastVisitedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        address: String? = nil,
        coordinate: GeoCoordinate,
        category: PlaceCategory = .labeledPlaces,
        lastVisitedAt: Date = .now
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = address?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.address = (trimmedAddress?.isEmpty == false) ? trimmedAddress : nil
        self.coordinate = coordinate
        self.category = category
        self.lastVisitedAt = lastVisitedAt
    }

    init(destination: Destination, category: PlaceCategory = .labeledPlaces, lastVisitedAt: Date = .now) {
        self.init(
            name: destination.name,
            address: destination.address,
            coordinate: destination.coordinate,
            category: category,
            lastVisitedAt: lastVisitedAt
        )
    }

    var destination: Destination {
        Destination(name: name, coordinate: coordinate, address: address)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var accessibilitySummary: String {
        if let address, !address.isEmpty {
            return "\(name), \(address)"
        }
        return name
    }

    func asSamplePlace() -> SamplePlace {
        SamplePlace(
            id: "recent-\(id.uuidString)",
            name: name,
            address: address ?? "",
            category: category,
            rating: 0,
            reviewCount: 0,
            recordedRouteCount: 0,
            isSaved: false,
            isRecent: true,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    /// Two destinations refer to the same place if their name and coordinates match within ~15m,
    /// or if their coordinates match within ~5m.
    func matches(destination: Destination) -> Bool {
        let latDiff = abs(coordinate.latitude - destination.coordinate.latitude)
        let lonDiff = abs(coordinate.longitude - destination.coordinate.longitude)
        if latDiff < 0.00005 && lonDiff < 0.00005 {
            return true
        }
        let lhs = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = destination.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return !lhs.isEmpty && lhs == rhs && latDiff < 0.00015 && lonDiff < 0.00015
    }

    func matches(query: String, category: PlaceCategory? = nil) -> Bool {
        if let category, self.category != category {
            return false
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let fields = [name, address ?? ""]
        if fields.contains(where: { $0.localizedCaseInsensitiveContains(trimmed) }) {
            return true
        }
        let initials = name
            .split(whereSeparator: \.isWhitespace)
            .compactMap(\.first)
            .map(String.init)
            .joined()
        return initials.localizedCaseInsensitiveContains(trimmed)
    }
}

/// Persists the user's last 10 navigated destinations in `UserDefaults`, newest first, deduplicated.
@MainActor
@Observable
final class RecentPlacesStore {
    static let maxCount = 10

    private(set) var places: [RecentPlace]

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let storageKey: String

    init(defaults: UserDefaults, storageKey: String = "recentPlaces") {
        self.defaults = defaults
        self.storageKey = storageKey
        self.places = Self.load(from: defaults, key: storageKey)
    }

    /// In-memory store for isolated tests and SwiftUI previews.
    init(places: [RecentPlace] = []) {
        self.defaults = nil
        self.storageKey = "recentPlaces"
        self.places = Array(places.prefix(Self.maxCount))
    }

    /// Records a destination when a trip starts, moving any matching destination to the top and keeping at most 10.
    @discardableResult
    func record(destination: Destination, category: PlaceCategory = .labeledPlaces, at date: Date = .now) -> RecentPlace {
        let existingID = places.first(where: { $0.matches(destination: destination) })?.id
        places.removeAll { $0.matches(destination: destination) }

        let recorded = RecentPlace(
            id: existingID ?? UUID(),
            name: destination.name,
            address: destination.address,
            coordinate: destination.coordinate,
            category: category,
            lastVisitedAt: date
        )
        places.insert(recorded, at: 0)
        if places.count > Self.maxCount {
            places.removeLast(places.count - Self.maxCount)
        }
        persist()
        return recorded
    }

    @discardableResult
    func record(plan: TripPlan, at date: Date = .now) -> RecentPlace {
        let destination = plan.plannedRoute?.destination ?? Destination(
            name: plan.place.name,
            coordinate: GeoCoordinate(latitude: plan.place.latitude, longitude: plan.place.longitude),
            address: plan.place.address.isEmpty ? nil : plan.place.address
        )
        return record(destination: destination, category: plan.place.category, at: date)
    }

    func clear() {
        places.removeAll()
        persist()
    }

    func matching(query: String, category: PlaceCategory? = nil) -> [RecentPlace] {
        places.filter { $0.matches(query: query, category: category) }
    }

    private func persist() {
        guard let defaults else { return }
        if places.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(places) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func load(from defaults: UserDefaults, key: String) -> [RecentPlace] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RecentPlace].self, from: data) else {
            return []
        }
        return Array(decoded.prefix(maxCount))
    }
}
