import Foundation

/// Near the destination, turns a door CV sees into "Entrance slightly right, 5 metres." (LAND-4).
///
/// Each door is spoken once, and doors are spaced out, so several in view don't crowd out the arrival.
struct EntranceGuide {
    private var spokenKeys: Set<String> = []
    private var lastSpokenAt: Date?

    // the last stretch of a route, where the building is close enough that its doors are the next thing to find
    static let range: Double = 30
    // farther than this a door is more likely a neighbour's than the destination's
    private static let maximumDoorDistance: Double = 25
    private static let spacing: TimeInterval = 8
    private static let minimumConfidence: Float = 0.5

    /// - Parameters:
    ///   - remaining: metres left on the route.
    ///   - hasArrived: past arrival the doors still matter, since arrival is often the pavement outside.
    mutating func guidance(for observation: LandmarkObservation, remaining: Double, hasArrived: Bool,
                           at time: Date) -> String? {
        guard observation.kind == .entrance, observation.confidence >= Self.minimumConfidence,
              hasArrived || remaining <= Self.range,
              (observation.distance ?? 0) <= Self.maximumDoorDistance,
              !spokenKeys.contains(observation.key),
              lastSpokenAt.map({ time.timeIntervalSince($0) >= Self.spacing }) ?? true
        else { return nil }
        spokenKeys.insert(observation.key)
        lastSpokenAt = time
        return Self.text(for: observation)
    }

    static func text(for observation: LandmarkObservation) -> String {
        // without depth there is no direction to give, and a guessed one would be worse than none
        guard let bearing = observation.bearing else { return "Entrance in view." }
        let direction = SpokenPhrasing.direction(bearing)
        guard let distance = observation.distance else { return "Entrance \(direction)." }
        return "Entrance \(direction), \(SpokenPhrasing.hedgedDistance(distance, accuracy: observation.distanceAccuracy))."
    }
}
