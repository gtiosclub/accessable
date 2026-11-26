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
        stairs = kinds.count { $0 == .stairs }
        elevators = kinds.count { $0 == .elevator }
        escalators = kinds.count { $0 == .escalator }
        crosswalks = crossings.count
        avoidedReports = Self.liveCounts(route.avoidedReports)
        unavoidedReports = Self.liveCounts(route.unavoidedReports)
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
        var sentences = ["\(time) \(counts.joined(separator: ", "))."]
        if !avoidedReports.isEmpty {
            sentences.append("Avoiding \(Self.reported(avoidedReports)).")
        }
        if !unavoidedReports.isEmpty {
            let verb = unavoidedReports.values.reduce(0, +) == 1 ? "is" : "are"
            sentences.append("\(Self.reported(unavoidedReports)) \(verb) on this route.")
        }
        return sentences.joined(separator: " ")
    }

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
