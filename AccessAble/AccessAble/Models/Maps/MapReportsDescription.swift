import Foundation

/// The reports on the trip map, for its one VoiceOver label: "2 reports on or near your route: construction, 40 metres
/// ahead on your route; closed entrance, 120 metres at 2 o'clock." Nearest first, and only the nearest few, so the
/// label stays short enough to listen to.
enum MapReportsDescription {
    static let maximumDescribed = 3

    /// - Parameters:
    ///   - walked: Metres along `route` the user has walked, for the reports on the route ahead.
    ///   - location, heading: Where the user is and the way they are going, in degrees from true north, for the
    ///     others; without a heading they get a distance only, and without a location their kind only.
    /// - Returns: Nil when there are no reports.
    static func text(
        _ reports: [Report],
        route: NavigationRoute?,
        walked: Double?,
        location: GeoCoordinate?,
        heading: Double?,
        distances: DistanceFormatter
    ) -> String? {
        guard !reports.isEmpty else { return nil }
        let described = reports
            .map { report -> (distance: Double, text: String) in
                let name = name(of: report.kind)
                if let route, let walked,
                   let along = ReportExclusions.distanceAlong(route, passing: report, from: walked) {
                    let ahead = along - walked
                    return (ahead, "\(name), \(distances.words(ahead)) ahead on your route")
                }
                guard let location else { return (.infinity, name) }
                let distance = report.distance(from: location)
                guard let heading else { return (distance, "\(name), \(distances.words(distance)) away") }
                let bearing = RelativeBearing.from(
                    heading: heading, toAbsoluteBearing: GeoMath.bearing(from: location, to: report.coordinate)
                )
                return (distance, "\(name), \(distances.words(distance)) at \(SpokenPhrasing.clock(bearing))")
            }
            .sorted { $0.distance < $1.distance }
            .map(\.text)
        var parts = Array(described.prefix(maximumDescribed))
        if described.count > maximumDescribed { parts.append("and \(described.count - maximumDescribed) more") }
        let count = reports.count == 1 ? "1 report" : "\(reports.count) reports"
        return "\(count) on or near your route: \(parts.joined(separator: "; "))."
    }

    private static func name(of kind: ReportKind) -> String {
        switch kind {
        case .construction: "construction"
        case .blockedPath: "blocked path"
        case .closedEntrance: "closed entrance"
        case .elevatorOut: "elevator out of service"
        case .other: "reported problem"
        }
    }
}
