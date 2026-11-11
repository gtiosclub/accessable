import CoreLocation
import Foundation
import MapKit

/// Owner: Maps + Location (2.1). Answers "where am I": the address the user is at and the
/// nearest named place, from a fresh GPS fix and Apple Maps.
///
/// Location updates run only while it waits for a fix, so asking doesn't keep GPS on. An
/// answer is reused for `freshness` seconds, since a question can ask for it more than once.
actor LocationDescriber: LocationContextProviding {
    /// An answer this recent is reused rather than asked for again.
    static let freshness: TimeInterval = 20
    /// How long to wait for a usable fix before giving up.
    private let fixTimeout: Duration
    /// A fix rougher than this, in metres, could put the user in the wrong building.
    static let maximumAccuracy: Double = 100
    /// Named places further than this, in metres, aren't "near".
    static let nearbyRadius: Double = 150

    private let location: any LocationProvider
    private let distances: DistanceSettings
    private var cached: (text: String, at: Date)?

    init(
        location: any LocationProvider,
        distances: DistanceSettings = DistanceSettings(units: .metres),
        fixTimeout: Duration = .seconds(8)
    ) {
        self.location = location
        self.distances = distances
        self.fixTimeout = fixTimeout
    }

    func currentLocationDescription() async -> String? {
        if let cached, Date.now.timeIntervalSince(cached.at) < Self.freshness { return cached.text }
        guard let fix = await firstFix() else { return nil }
        guard let text = await Self.describe(fix, distances: distances.formatter) else { return nil }
        cached = (text, .now)
        return text
    }

    /// The first fix good enough to name a street, or nil if none comes in time.
    private func firstFix() async -> LocationSample? {
        await withTaskGroup(of: LocationSample?.self) { group in
            group.addTask { [location] in
                for await sample in location.locationSamples() where sample.horizontalAccuracy <= Self.maximumAccuracy {
                    return sample
                }
                return nil
            }
            group.addTask { [fixTimeout] in
                try? await Task.sleep(for: fixTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// "You're at 351 Ferst Dr NW. The nearest place is Clough Commons, about 40 metres away."
    /// Off any actor: MapKit's requests and results aren't Sendable, a String is.
    @concurrent private static func describe(_ fix: LocationSample, distances: DistanceFormatter) async -> String? {
        let here = CLLocation(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        var sentences: [String] = []

        if let request = MKReverseGeocodingRequest(location: here),
           let item = try? await request.mapItems.first,
           let address = item.address?.shortAddress ?? item.name {
            sentences.append("You're at \(address).")
        }

        let nearby = MKLocalPointsOfInterestRequest(center: here.coordinate, radius: nearbyRadius)
        if let response = try? await MKLocalSearch(request: nearby).start() {
            let nearest = response.mapItems
                .compactMap { item -> (name: String, metres: Double)? in
                    guard let name = item.name else { return nil }
                    return (name, item.location.distance(from: here))
                }
                .min { $0.metres < $1.metres }
            if let nearest {
                sentences.append(nearest.metres < 15
                    ? "You're at \(nearest.name)."
                    : "The nearest place is \(nearest.name), \(distances.spoken(nearest.metres)) away.")
            }
        }

        guard !sentences.isEmpty else { return nil }
        if fix.horizontalAccuracy > 30 {
            sentences.append("Your position is only accurate to \(distances.spoken(fix.horizontalAccuracy)).")
        }
        return sentences.joined(separator: " ")
    }
}
