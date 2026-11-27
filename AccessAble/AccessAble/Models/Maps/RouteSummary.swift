import Foundation

/// What a walk involves, said before the user commits to it (NAV-7): "About 6 minutes, 450 feet.
/// 3 turns, 1 flight of stairs, 2 crosswalks. Avoiding 1 reported construction site."
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
    /// Live reports near the route that it goes around, and those it passes, by kind. Counts only: reports name their
    /// reporter.
    var avoidedReports: [ReportKind: Int]
    var unavoidedReports: [ReportKind: Int]

    init(route: NavigationRoute, crossings: [RouteCrossing]) {
        duration = route.estimatedDuration
        distance = route.totalDistance
        let kinds = route.steps.map(\.kind)
        turns = kinds.count { [.turnLeft, .turnRight, .slightLeft, .slightRight, .uTurn].contains($0) }
        stairs = Self.stairs(on: route)
        elevators = Self.elevators(on: route)
        escalators = kinds.count { $0 == .escalator }
        crosswalks = crossings.count
        avoidedReports = Self.liveCounts(route.avoidedReports)
        unavoidedReports = Self.liveCounts(route.unavoidedReports)
    }

    /// The summary in the user's units, for speech and the screen alike. What the route still has that `preferences`
    /// asked to avoid comes first, and isn't counted again after.
    func text(distances: DistanceFormatter, preferences: RoutePreferences) -> String {
        let minutes = max(1, Int((duration / 60).rounded()))
        let time = "About \(minutes) \(minutes == 1 ? "minute" : "minutes"), \(distances.words(distance))."
        let warnsOfStairs = preferences.avoidStairs && stairs > 0
        let warnsOfElevators = preferences.avoidElevators && elevators > 0
        // turns always, so a walk with none says so before its other counts
        let counts = [
            turns == 0 ? "No turns" : Self.count(turns, "turn", "turns"),
            warnsOfStairs ? nil : Self.stairsCount(stairs),
            warnsOfElevators ? nil : Self.elevatorsCount(elevators),
            Self.count(escalators, "escalator", "escalators"),
            Self.count(crosswalks, "crosswalk", "crosswalks"),
        ].compactMap { $0 }
        var sentences = Self.warnings(stairs: stairs, elevators: elevators, preferences: preferences)
        sentences.append("\(time) \(counts.joined(separator: ", ")).")
        if !avoidedReports.isEmpty {
            sentences.append("Avoiding \(Self.reported(avoidedReports)).")
        }
        if !unavoidedReports.isEmpty {
            let verb = unavoidedReports.values.reduce(0, +) == 1 ? "is" : "are"
            sentences.append("\(Self.reported(unavoidedReports)) \(verb) on this route.")
        }
        return sentences.joined(separator: " ")
    }

    /// "No step-free route found. This route has 1 flight of stairs.", for each of stairs and elevators that `route`
    /// still uses though `preferences` asked to avoid them; empty when it keeps to them. The other preferences have no
    /// count on the route to check.
    static func preferenceWarnings(on route: NavigationRoute, preferences: RoutePreferences) -> [String] {
        warnings(stairs: stairs(on: route), elevators: elevators(on: route), preferences: preferences)
    }

    /// Flights of stairs, counted the same for the summary and the trip's warning.
    private static func stairs(on route: NavigationRoute) -> Int { route.steps.count { $0.kind == .stairs } }
    private static func elevators(on route: NavigationRoute) -> Int { route.steps.count { $0.kind == .elevator } }

    private static func warnings(stairs: Int, elevators: Int, preferences: RoutePreferences) -> [String] {
        var warnings: [String] = []
        if preferences.avoidStairs, let stairs = stairsCount(stairs) {
            warnings.append("No step-free route found. This route has \(stairs).")
        }
        if preferences.avoidElevators, let elevators = elevatorsCount(elevators) {
            warnings.append("No route without elevators found. This route uses \(elevators).")
        }
        return warnings
    }

    private static func stairsCount(_ n: Int) -> String? { count(n, "flight of stairs", "flights of stairs") }
    private static func elevatorsCount(_ n: Int) -> String? { count(n, "elevator", "elevators") }

    private static func liveCounts(_ reports: [Report]) -> [ReportKind: Int] {
        let now = Date.now
        return reports.filter { $0.expiresAt > now }.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 }
    }

    /// "2 reported construction sites and 1 blocked path": most first, then in `ReportKind` order.
    private static func reported(_ counts: [ReportKind: Int]) -> String {
        // filtered from allCases so they start in its order, which the stable sort keeps between equal counts
        let kinds = ReportKind.allCases.filter { counts[$0] != nil }
            .sorted { counts[$0, default: 0] > counts[$1, default: 0] }
        let parts = kinds.enumerated().map { index, kind in
            let count = counts[kind, default: 0]
            // the other kind's name says "reported" itself
            let reported = index == 0 && kind != .other ? "reported " : ""
            return "\(count) \(reported)\(name(of: kind, plural: count != 1))"
        }
        guard let last = parts.last, parts.count > 1 else { return parts.joined() }
        return parts.dropLast().joined(separator: ", ") + " and " + last
    }

    private static func name(of kind: ReportKind, plural: Bool) -> String {
        switch kind {
        case .construction: plural ? "construction sites" : "construction site"
        case .blockedPath: plural ? "blocked paths" : "blocked path"
        case .closedEntrance: plural ? "closed entrances" : "closed entrance"
        case .elevatorOut: plural ? "elevators out of service" : "elevator out of service"
        // as the map says it
        case .other: plural ? "reported problems" : "reported problem"
        }
    }

    private static func count(_ n: Int, _ singular: String, _ plural: String) -> String? {
        n == 0 ? nil : "\(n) \(n == 1 ? singular : plural)"
    }
}
