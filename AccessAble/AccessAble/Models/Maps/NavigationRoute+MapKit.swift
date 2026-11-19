import MapKit

extension NavigationRoute {
    /// The route's bounds grown by `margin` (a fraction of the bounds) on every side, so the line and its markers
    /// stay clear of the map's edges. Each side is at least `minimumSpan` metres, so a short route isn't zoomed in
    /// to a single building.
    func cameraRect(margin: Double = 0.2, minimumSpan: Double = 200) -> MKMapRect {
        let points = coordinates.map { MKMapPoint($0.clCoordinate) }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let center = MKMapPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)

        // map points per metre grow away from the equator
        let minimumSize = minimumSpan * MKMapPointsPerMeterAtLatitude(center.coordinate.latitude)
        let width = max((maxX - minX) * (1 + 2 * margin), minimumSize)
        let height = max((maxY - minY) * (1 + 2 * margin), minimumSize)
        return MKMapRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }
}

// MARK: - Apple Maps walking routes

/// One step of an Apple Maps route, reduced to what the conversion needs, so it can be tested without an `MKRoute`.
struct AppleMapsStep: Equatable, Sendable {
    /// `MKRoute.Step.instructions`; Apple leaves it empty for the first step of most walking routes.
    var instructions: String
    /// First coordinate of the step's polyline; nil when the polyline is empty.
    var start: GeoCoordinate?
}

extension NavigationRoute {
    /// Converts Apple's walking route. Apple doesn't know about stairs, kerbs or step-free paths, so whoever uses this
    /// must tell the user (see `FallbackRoutingService`).
    /// - Parameter duration: Seconds; nil keeps Apple's `expectedTravelTime`.
    init(appleMapsRoute route: MKRoute, duration: Double? = nil) throws(ValidationError) {
        try self.init(
            appleMapsCoordinates: route.polyline.geoCoordinates,
            steps: route.steps.map {
                AppleMapsStep(instructions: $0.instructions, start: $0.polyline.geoCoordinates.first)
            },
            estimatedDuration: duration ?? route.expectedTravelTime
        )
    }

    /// The conversion itself. Steps are placed at the route coordinate nearest their start, never before the previous
    /// step. The first step always departs and the route always ends with an arrival at its last coordinate, which
    /// Apple's own last step ("Arrive at the destination") becomes when it says so.
    init(appleMapsCoordinates rawCoordinates: [GeoCoordinate], steps appleSteps: [AppleMapsStep],
         estimatedDuration: Double) throws(ValidationError) {
        // Apple's polylines repeat the point where two steps meet
        var coordinates: [GeoCoordinate] = []
        for coordinate in rawCoordinates where coordinate != coordinates.last {
            coordinates.append(coordinate)
        }
        guard coordinates.count >= 2 else { throw .tooFewCoordinates }
        let lastIndex = coordinates.count - 1

        var steps: [RouteStep] = []
        var previousIndex = 0
        for (position, appleStep) in appleSteps.enumerated() {
            let text = appleStep.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            let isLast = position == appleSteps.count - 1
            if position == 0 {
                let instruction = text.isEmpty ? "Follow the path" : text
                steps.append(RouteStep(kind: .depart, coordinateIndex: 0, instruction: instruction,
                                       spokenInstruction: Self.appleMapsSpokenText(instruction)))
                continue
            }
            // an empty middle step has nothing to say
            guard !text.isEmpty else { continue }
            if isLast, Self.appleMapsTextIsArrival(text) {
                steps.append(RouteStep(kind: .arrive, coordinateIndex: lastIndex, instruction: text,
                                       spokenInstruction: Self.appleMapsSpokenText(text)))
                continue
            }
            let index = appleStep.start.map { Self.nearestIndex(to: $0, in: coordinates, from: previousIndex) }
                ?? previousIndex
            previousIndex = index
            steps.append(RouteStep(kind: Self.appleMapsManeuverKind(for: text), coordinateIndex: index,
                                   instruction: text, spokenInstruction: Self.appleMapsSpokenText(text)))
        }
        if steps.isEmpty {
            steps.append(RouteStep(kind: .depart, coordinateIndex: 0, instruction: "Follow the path",
                                   spokenInstruction: "Follow the path."))
        }
        if steps.last?.kind != .arrive {
            steps.append(RouteStep(kind: .arrive, coordinateIndex: lastIndex, instruction: "Arrive at the destination",
                                   spokenInstruction: "You have arrived."))
        }
        try self.init(coordinates: coordinates, steps: steps, estimatedDuration: estimatedDuration)
    }

    /// The first coordinate within a metre of `point` at or after `start`, otherwise the nearest one, so a route
    /// that passes the same spot twice doesn't jump ahead.
    private static func nearestIndex(to point: GeoCoordinate, in coordinates: [GeoCoordinate], from start: Int) -> Int {
        var best = start
        var bestDistance = Double.infinity
        for index in start..<coordinates.count {
            let distance = GeoMath.distance(from: point, to: coordinates[index])
            if distance <= 1 { return index }
            if distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    /// Apple's instruction text, lowercased, with punctuation turned into spaces and padded, so phrases match whole
    /// words: "U-turn" reads " u turn ".
    private static func padded(_ text: String) -> String {
        " " + text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ") + " "
    }

    static func appleMapsTextIsArrival(_ text: String) -> Bool {
        let words = padded(text)
        return [" arrive ", " arrived ", " destination "].contains { words.contains($0) }
    }

    /// The maneuver Apple's instruction text describes. Apple gives no maneuver type, only the text. Stairs come first:
    /// they are what a user of this app most needs warning about, even when the same step also turns.
    static func appleMapsManeuverKind(for text: String) -> ManeuverKind {
        let words = padded(text)
        func says(_ phrases: [String]) -> Bool { phrases.contains { words.contains(" \($0) ") } }
        if says(["stairs", "stair", "staircase", "stairway", "steps"]) { return .stairs }
        if says(["elevator", "lift"]) { return .elevator }
        if says(["escalator"]) { return .escalator }
        if says(["u turn", "uturn", "turn around"]) { return .uTurn }
        if says(["slight left", "slightly left", "bear left", "keep left", "stay left"]) { return .slightLeft }
        if says(["slight right", "slightly right", "bear right", "keep right", "stay right"]) { return .slightRight }
        if says(["turn left", "sharp left", "make a left", "take a left", "go left", "left onto", "left on", "left at",
                 "left to", "left toward", "left towards"]) || words.hasPrefix(" left ") { return .turnLeft }
        if says(["turn right", "sharp right", "make a right", "take a right", "go right", "right onto", "right on",
                 "right at", "right to", "right toward", "right towards"]) || words.hasPrefix(" right ") {
            return .turnRight
        }
        if says(["cross", "crosswalk", "crossing"]) { return .cross }
        return .straight
    }

    private static let streetSuffixes = [
        "St": "Street", "Dr": "Drive", "Ave": "Avenue", "Av": "Avenue", "Rd": "Road", "Blvd": "Boulevard",
        "Ln": "Lane", "Pl": "Place", "Ct": "Court", "Pkwy": "Parkway", "Hwy": "Highway", "Cir": "Circle",
        "Ter": "Terrace", "Trl": "Trail", "Sq": "Square",
    ]
    private static let directionSuffixes = [
        "NW": "Northwest", "NE": "Northeast", "SW": "Southwest", "SE": "Southeast",
    ]

    /// Text for speech from Apple's display text: no compass start ("Head north on X" becomes "Follow X"), street
    /// abbreviations spelled out so "Ferst Dr NW" isn't read as "Ferst Doctor N W", and a full stop at the end. An
    /// abbreviation is only expanded where it ends a street name, so "Dr Martin Luther King Jr Dr" keeps its first "Dr".
    static func appleMapsSpokenText(_ text: String) -> String {
        let source = RouteStep.withoutCompassDirection(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var words = source.split(separator: " ").map(String.init)
        func split(_ word: String) -> (core: String, trailing: String) {
            let core = word.reversed().drop(while: { ".,;:!?".contains($0) }).reversed()
            return (String(core), String(word.dropFirst(core.count)))
        }
        for index in words.indices {
            let (core, trailing) = split(words[index])
            let isLastWord = index == words.count - 1
            let nextCore = isLastWord ? nil : split(words[index + 1]).core
            let endsName = isLastWord || !trailing.isEmpty || nextCore.map { directionSuffixes[$0] != nil } == true
            if index > 0, endsName, let expanded = streetSuffixes[core] {
                words[index] = expanded + trailing
            } else if index > 0, isLastWord || !trailing.isEmpty, let expanded = directionSuffixes[core] {
                words[index] = expanded + trailing
            }
        }
        let spoken = words.joined(separator: " ")
        guard let last = spoken.last else { return spoken }
        return ".!?".contains(last) ? spoken : spoken + "."
    }
}

extension MKMultiPoint {
    var geoCoordinates: [GeoCoordinate] {
        guard pointCount > 0 else { return [] }
        var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates.map { GeoCoordinate($0) }
    }
}
