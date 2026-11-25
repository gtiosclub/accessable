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
    /// `MKRoute.Step.instructions`, in the device's language; Apple leaves it empty for the first step of most
    /// walking routes.
    var instructions: String
    /// First coordinate of the step's polyline; nil when the polyline is empty.
    var start: GeoCoordinate?
}

extension NavigationRoute {
    /// Converts Apple's walking route, with `source` `.appleMaps`. Apple doesn't know about stairs, kerbs or step-free
    /// paths, so whoever shows the route must tell the user (see `RouteSource.backupNotice`).
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
    /// Apple's own last step becomes when it says so or starts there. A step whose text names no maneuver this knows,
    /// such as one in another language, takes its turn from the route's shape.
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
            if position == 0 {
                // the trip speaks the first step's display text, so it is spelled out like the spoken text
                let instruction = text.isEmpty ? "Follow the path" : Self.appleMapsExpandedText(instruction: text)
                steps.append(RouteStep(kind: .depart, coordinateIndex: 0, instruction: instruction,
                                       spokenInstruction: Self.appleMapsSpokenText(instruction)))
                continue
            }
            // an empty middle step has nothing to say
            guard !text.isEmpty else { continue }
            let index = appleStep.start.map { Self.nearestIndex(to: $0, in: coordinates, from: previousIndex) }
                ?? previousIndex
            if position == appleSteps.count - 1, index == lastIndex || Self.appleMapsTextIsArrival(text) {
                steps.append(RouteStep(kind: .arrive, coordinateIndex: lastIndex, instruction: text,
                                       spokenInstruction: Self.appleMapsArrivalSpeech(text)))
                continue
            }
            previousIndex = index
            let kind = Self.appleMapsManeuverKind(for: text) ?? Self.turnKind(at: index, in: coordinates)
            steps.append(RouteStep(kind: kind, coordinateIndex: index, instruction: text,
                                   spokenInstruction: Self.appleMapsSpokenText(text)))
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
        source = .appleMaps
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

    /// Metres before and after a step's start that `turnKind` measures the way in and out over, so a kink in the
    /// polyline right at the corner doesn't decide the turn.
    private static let turnMeasureDistance: Double = 10

    /// The turn the route makes at `index`, from the change of bearing there: under 20° straight, under 45° slight,
    /// under 150° a turn, sharp ones included, and beyond that a U-turn.
    static func turnKind(at index: Int, in coordinates: [GeoCoordinate]) -> ManeuverKind {
        guard index > 0, index < coordinates.count - 1 else { return .straight }
        let corner = coordinates[index]
        let before = coordinates[..<index].last { GeoMath.distance(from: $0, to: corner) >= turnMeasureDistance }
            ?? coordinates[0]
        let after = coordinates[(index + 1)...].first {
            GeoMath.distance(from: corner, to: $0) >= turnMeasureDistance
        } ?? coordinates[coordinates.count - 1]
        let change = GeoMath.normalizedBearing(
            GeoMath.bearing(from: corner, to: after) - GeoMath.bearing(from: before, to: corner) + 180
        ) - 180
        switch abs(change) {
        case ..<20: return .straight
        case ..<45: return change < 0 ? .slightLeft : .slightRight
        case ..<150: return change < 0 ? .turnLeft : .turnRight
        default: return .uTurn
        }
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

    /// Apple's arrival, "Arrive at the destination", said as Valhalla's are: "You have arrived.", or which side the
    /// destination is on when Apple says.
    static func appleMapsArrivalSpeech(_ text: String) -> String {
        let words = padded(text)
        func says(_ phrases: [String]) -> Bool { phrases.contains { words.contains(" \($0) ") } }
        if says(["on the left", "on your left"]) { return "Your destination is on the left." }
        if says(["on the right", "on your right"]) { return "Your destination is on the right." }
        return "You have arrived."
    }

    /// The maneuver Apple's English instruction text describes, or nil when it names none, as in another language.
    /// Apple gives no maneuver type, only the text. A turn comes before stairs, elevators and escalators in the same
    /// step, which the spoken text still names: "Turn left and take the steps down" must still be a left turn.
    static func appleMapsManeuverKind(for text: String) -> ManeuverKind? {
        let words = padded(text)
        func says(_ phrases: [String]) -> Bool { phrases.contains { words.contains(" \($0) ") } }
        if says(["u turn", "uturn", "turn around"]) { return .uTurn }
        if says(["slight left", "slightly left", "bear left", "keep left", "stay left"]) { return .slightLeft }
        if says(["slight right", "slightly right", "bear right", "keep right", "stay right"]) { return .slightRight }
        if says(["turn left", "sharp left", "make a left", "take a left", "go left", "left onto", "left on", "left at",
                 "left to", "left toward", "left towards"]) || words.hasPrefix(" left ") { return .turnLeft }
        if says(["turn right", "sharp right", "make a right", "take a right", "go right", "right onto", "right on",
                 "right at", "right to", "right toward", "right towards"]) || words.hasPrefix(" right ") {
            return .turnRight
        }
        if says(["stairs", "stair", "staircase", "stairway", "steps"]) { return .stairs }
        if says(["elevator", "lift"]) { return .elevator }
        if says(["escalator"]) { return .escalator }
        if says(["cross", "crosswalk", "crossing"]) { return .cross }
        if says(["continue", "proceed", "head", "walk", "go straight", "straight", "follow"]) { return .straight }
        return nil
    }

    private static let streetSuffixes = [
        "St": "Street", "Dr": "Drive", "Ave": "Avenue", "Av": "Avenue", "Rd": "Road", "Blvd": "Boulevard",
        "Ln": "Lane", "Pl": "Place", "Ct": "Court", "Pkwy": "Parkway", "Hwy": "Highway", "Cir": "Circle",
        "Ter": "Terrace", "Trl": "Trail", "Sq": "Square",
    ]
    private static let directionSuffixes = [
        "NW": "Northwest", "NE": "Northeast", "SW": "Southwest", "SE": "Southeast",
        "N": "North", "S": "South", "E": "East", "W": "West",
    ]

    /// Apple's display text with street abbreviations spelled out, so "Ferst Dr NW" isn't read as "Ferst Doctor N W".
    /// A street abbreviation is only expanded where it ends a street name, so "Dr Martin Luther King Jr Dr" keeps its
    /// first "Dr"; a direction only after a street abbreviation, or for "NW" and the like at the end of a phrase, so
    /// "Turn left onto E St" keeps its "E".
    static func appleMapsExpandedText(instruction text: String) -> String {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        func split(_ word: String) -> (core: String, trailing: String) {
            let core = word.reversed().drop(while: { ".,;:!?".contains($0) }).reversed()
            return (String(core), String(word.dropFirst(core.count)))
        }
        var words = original
        for index in original.indices where index > 0 {
            let (core, trailing) = split(original[index])
            let endsPhrase = index == original.count - 1 || !trailing.isEmpty
            let nextIsDirection = endsPhrase ? false : directionSuffixes[split(original[index + 1]).core] != nil
            let previous = split(original[index - 1])
            let followsStreet = previous.trailing.isEmpty && streetSuffixes[previous.core] != nil
            if let expanded = streetSuffixes[core], endsPhrase || nextIsDirection {
                words[index] = expanded + trailing
            } else if let expanded = directionSuffixes[core], followsStreet || (core.count == 2 && endsPhrase) {
                words[index] = expanded + trailing
            }
        }
        return words.joined(separator: " ")
    }

    /// Text for speech from Apple's display text: spelled out as `appleMapsExpandedText(instruction:)`, with no
    /// compass start ("Head north on X" becomes "Follow X"), and a full stop at the end.
    static func appleMapsSpokenText(_ text: String) -> String {
        let spoken = RouteStep.withoutCompassDirection(appleMapsExpandedText(instruction: text))
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
