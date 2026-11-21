import Foundation

/// What a walk involves, said before the user commits to it (NAV-7): "About 6 minutes, 450 feet.
/// 3 turns, 1 flight of stairs, 2 crosswalks."
struct RouteSummary: Equatable, Sendable {
    /// Seconds.
    var duration: TimeInterval
    /// Metres.
    var distance: Double
    /// Turns of any size, U-turns included.
    var turns: Int
    /// Flights of stairs.
    var stairs: Int
    var elevators: Int
    var escalators: Int
    /// Crossings placed on the route, marked or not.
    var crosswalks: Int

    init(route: NavigationRoute, crossings: [RouteCrossing]) {
        duration = route.estimatedDuration
        distance = route.totalDistance
        let kinds = route.steps.map(\.kind)
        turns = kinds.count { [.turnLeft, .turnRight, .slightLeft, .slightRight, .uTurn].contains($0) }
        stairs = kinds.count { $0 == .stairs }
        elevators = kinds.count { $0 == .elevator }
        escalators = kinds.count { $0 == .escalator }
        crosswalks = crossings.count
    }

    /// The summary in the user's units, for speech and the screen alike.
    func text(distances: DistanceFormatter) -> String {
        let minutes = max(1, Int((duration / 60).rounded()))
        let time = "About \(minutes) \(minutes == 1 ? "minute" : "minutes"), \(distances.words(distance))."
        // turns always, so a walk with none says so before its other counts
        let counts = [
            turns == 0 ? "No turns" : Self.count(turns, "turn", "turns"),
            Self.count(stairs, "flight of stairs", "flights of stairs"),
            Self.count(elevators, "elevator", "elevators"),
            Self.count(escalators, "escalator", "escalators"),
            Self.count(crosswalks, "crosswalk", "crosswalks"),
        ].compactMap { $0 }
        return "\(time) \(counts.joined(separator: ", "))."
    }

    private static func count(_ n: Int, _ singular: String, _ plural: String) -> String? {
        n == 0 ? nil : "\(n) \(n == 1 ? singular : plural)"
    }
}
