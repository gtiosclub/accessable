import Foundation

/// One of the eight compass points, used for spoken search results when the user's heading is unknown.
enum CardinalDirection: CaseIterable, Sendable {
    case north, northeast, east, southeast, south, southwest, west, northwest

    /// Eight 45° sectors centred on 0°, 45°, 90° and so on. Each sector holds its anticlockwise edge,
    /// so north is 337.5..<22.5, northeast is 22.5..<67.5, and so on.
    /// Returns `nil` when `bearing` is not finite.
    init?(bearing: Double) {
        guard bearing.isFinite else { return nil }
        let normalized = GeoMath.normalizedBearing(bearing)
        let sector = Int(((normalized + 22.5) / 45).rounded(.down)) % 8
        self = Self.allCases[sector]
    }

    var phrase: String {
        switch self {
        case .north: "north"
        case .northeast: "northeast"
        case .east: "east"
        case .southeast: "southeast"
        case .south: "south"
        case .southwest: "southwest"
        case .west: "west"
        case .northwest: "northwest"
        }
    }
}

/// Formats VoiceOver labels for destination search results with straight-line distance (`GeoMath` +
/// `DistanceFormatter`) and direction (`RelativeDirection` when NAV-2 knows the heading, otherwise
/// `CardinalDirection`) for the top 5 results only.
enum SearchResultSpeech {
    static let maxSpokenResults = 5
    /// Seconds; from an older fix, how far and which way a result lies isn't said.
    static let maximumFixAge: TimeInterval = 5

    /// Where to measure from: `fix`, or nil when there is none or it is older than `maximumFixAge` at `time`.
    static func origin(of fix: LocationSample?, at time: Date) -> GeoCoordinate? {
        guard let fix, time.timeIntervalSince(fix.timestamp) <= maximumFixAge else { return nil }
        return fix.coordinate
    }

    static func directionPhrase(
        from origin: GeoCoordinate,
        to target: GeoCoordinate,
        heading: UserHeading?
    ) -> String? {
        let bearing = GeoMath.bearing(from: origin, to: target)
        guard bearing.isFinite else { return nil }
        if let heading, heading.degrees.isFinite {
            return RelativeDirection(RelativeBearing.from(heading: heading.degrees, toAbsoluteBearing: bearing)).phrase
        }
        return CardinalDirection(bearing: bearing)?.phrase
    }

    static func label(
        for suggestion: SearchSuggestion,
        at index: Int,
        from origin: GeoCoordinate?,
        heading: UserHeading?,
        distances: DistanceFormatter
    ) -> String {
        var parts = [suggestion.title]
        if index < maxSpokenResults,
           let origin,
           let target = suggestion.coordinate,
           origin.latitude.isFinite, origin.longitude.isFinite,
           target.latitude.isFinite, target.longitude.isFinite {
            let metres = GeoMath.distance(from: origin, to: target)
            if metres.isFinite, let direction = directionPhrase(from: origin, to: target, heading: heading) {
                parts.append(distances.words(metres))
                parts.append(direction)
            }
        }
        if !suggestion.subtitle.isEmpty {
            parts.append(suggestion.subtitle)
        }
        return parts.joined(separator: ", ")
    }
}
