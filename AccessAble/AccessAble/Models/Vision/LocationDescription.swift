import Foundation
import Synchronization
#if canImport(FoundationModels)
import FoundationModels
#endif

// T22: the "Describe my location" AI mode. Where "Describe my surroundings" (T21) says what
// the camera sees, this says where the user is: the street, which way they face, the
// landmarks around them, with the signs and hazards the camera sees as context. "You're on
// Ferst Drive facing north. Klaus is ahead on your left."
//
// Computer Vision does not look places up. Maps and the phone's sensors hand it a
// `PlaceContext`, and this turns that into a short spoken answer under the user's T23
// ranking and the T24 rules. The context is a small input type of its own, so this works
// with whatever Maps provides and nothing waits on it.

/// A named place near the user, from Maps or from a sign the camera read.
struct PlaceLandmark: Equatable, Sendable {
    var name: String
    /// Relative to where the user faces. nil when only the distance is known.
    var bearing: RelativeBearing?
    /// Metres from the user, when known.
    var distance: Double?

    init(name: String, bearing: RelativeBearing? = nil, distance: Double? = nil) {
        self.name = name
        self.bearing = bearing
        self.distance = distance
    }

    /// From a compass bearing to the place and the way the user faces, both in degrees from
    /// true north, as a map gives them.
    init(name: String, compassBearing: Double, heading: Double, distance: Double? = nil) {
        self.init(name: name, bearing: .from(heading: heading, toAbsoluteBearing: compassBearing), distance: distance)
    }
}

/// Where the user is, as Maps and the phone's sensors know it. The input of T22.
struct PlaceContext: Equatable, Sendable {
    /// "Ferst Drive", as the user would say it.
    var street: String?
    /// The way the user faces, degrees from true north. nil when the compass can't be trusted.
    var heading: Double?
    /// How far GPS can be off, in metres.
    var positionAccuracy: Double?
    var landmarks: [PlaceLandmark] = []

    var isEmpty: Bool { street == nil && heading == nil && landmarks.isEmpty }
}

/// The eight points of the compass, from a heading.
enum CompassPoint: String, CaseIterable, Sendable {
    case north, northeast, east, southeast, south, southwest, west, northwest

    init(heading: Double) {
        let normalized = heading.truncatingRemainder(dividingBy: 360)
        let degrees = normalized < 0 ? normalized + 360 : normalized
        self = Self.allCases[Int((degrees / 45).rounded()) % 8]
    }
}

enum LocationPrompt {
    /// Stands in for the user's question, which this mode does not have.
    static let request = "Tell me where I am."

    /// Landmarks passed on to the model and the template: the nearest few.
    static let maxLandmarks = 3
    /// Positions rougher than this are said to be rough.
    static let roughPosition: Double = 30

    static let instructions = """
        You help a blind or low-vision person know where they are. \
        You cannot see anything. You get what maps and the phone know: the street, \
        which way they face, nearby landmarks with their direction and distance, \
        and some signs and hazards the camera sees.
        Rules:
        - Answer in two or three short sentences, under 40 words, using only that list.
        - Start with the street and which way they face, then the nearest landmarks \
        with where they are: ahead, on your left, on your right.
        - If a hazard is close ahead, mention it first.
        - If the list has no street, say you can't tell which street they are on. \
        Never guess street names, buildings or directions that are not in the list.
        - If the position is rough, say it may be off by that much.
        - Never say a street, crossing or path is safe or clear. You cannot judge traffic.
        - Speak in plain sentences. Don't copy the list's headings or dashes.
        """

    /// The facts in the user's order (T23): location first as it is the point of the question,
    /// then the camera's, grouped by category.
    static func prompt(context: PlaceContext, facts: ImageFacts, priorities: AIPriorities = .default) -> String {
        var lines: [String] = []
        if context.isEmpty {
            lines.append("Maps and the phone could not tell where the user is.")
        } else {
            lines.append("Where the user is:")
            lines.append("- Street: \(context.street ?? "unknown").")
            if let heading = context.heading {
                lines.append("- Facing \(CompassPoint(heading: heading).rawValue).")
            }
            if let accuracy = context.positionAccuracy, accuracy > roughPosition {
                lines.append("- Position is rough, off by up to about \(Int(accuracy.rounded())) metres.")
            }
            let landmarks = nearest(context.landmarks)
            if !landmarks.isEmpty {
                lines.append("Landmarks nearby:")
                lines += landmarks.map { "- \(describe($0))" }
            }
        }

        let hazards = facts.elevationHazards.map { "- \(SpokenPhrasing.describe($0))" }
            + facts.detections.filter { $0.isHazard && $0.label != "person" }.map { "- \(SpokenPhrasing.describe($0))" }
        let text = facts.text.map { "- \"\($0.string)\", \(AskAIPrompt.position(of: $0.boundingBox))" }
        let sections: [AIInfoCategory: (title: String, lines: [String])] = [
            .hazards: ("Hazards the camera sees:", hazards),
            .signsText: ("Signs the camera read:", text),
        ]
        for category in priorities.order {
            guard let section = sections[category], !section.lines.isEmpty else { continue }
            lines.append(section.title)
            lines += section.lines
        }
        lines.append("")
        lines.append("Request: \(request)")
        return lines.joined(separator: "\n")
    }

    static func nearest(_ landmarks: [PlaceLandmark]) -> [PlaceLandmark] {
        Array(landmarks.sorted { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }.prefix(maxLandmarks))
    }

    /// "Klaus ahead on your left, 40 metres." / "Clough Commons, 120 metres."
    static func describe(_ landmark: PlaceLandmark) -> String {
        var parts = landmark.name
        if let bearing = landmark.bearing {
            let side = SpokenPhrasing.direction(bearing)
            parts += side == "ahead" ? " ahead" : " \(side)"
        }
        if let distance = landmark.distance {
            parts += ", \(SpokenPhrasing.shortDistance(distance))"
        }
        return parts + "."
    }
}

/// The location answer without a language model: the same facts, put in the same words.
enum LocationTemplate {
    static let cannotTell = "I can't tell where you are."

    static func describe(context: PlaceContext) -> String {
        guard !context.isEmpty else { return cannotTell }
        var sentences: [String] = []
        switch (context.street, context.heading) {
        case let (street?, heading?):
            sentences.append("You're on \(street) facing \(CompassPoint(heading: heading).rawValue).")
        case let (street?, nil):
            sentences.append("You're on \(street).")
        case (nil, let heading?):
            sentences.append("I can't tell which street you're on. You're facing \(CompassPoint(heading: heading).rawValue).")
        case (nil, nil):
            sentences.append("I can't tell which street you're on.")
        }
        sentences += LocationPrompt.nearest(context.landmarks).map(sentence(for:))
        if let accuracy = context.positionAccuracy, accuracy > LocationPrompt.roughPosition {
            sentences.append("Your position may be off by about \(Int(accuracy.rounded())) metres.")
        }
        return sentences.joined(separator: " ")
    }

    /// "Klaus is on your left, 40 metres." / "Clough Commons is ahead."
    private static func sentence(for landmark: PlaceLandmark) -> String {
        var sentence = "\(landmark.name) is"
        if let bearing = landmark.bearing {
            let side = SpokenPhrasing.direction(bearing)
            sentence += side == "ahead" ? " ahead" : " \(side)"
        } else if landmark.distance == nil {
            return "\(landmark.name) is nearby."
        }
        if let distance = landmark.distance {
            sentence += landmark.bearing == nil ? " \(SpokenPhrasing.shortDistance(distance)) away" : ", \(SpokenPhrasing.shortDistance(distance))"
        }
        return sentence + "."
    }
}

/// Writes the location answer from the context and what the camera saw.
protocol LocationResponding: Sendable {
    func answer(context: PlaceContext, facts: ImageFacts) async throws -> String
}

/// The on-device model with the location prompt and the user's T23 ranking; the template
/// where Apple Intelligence is unavailable or the model fails.
struct OnDeviceLocationResponder: LocationResponding {
    var settings = AskAISettings()

    func answer(context: PlaceContext, facts: ImageFacts) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *), SystemLanguageModel.default.isAvailable {
            do {
                let session = LanguageModelSession(instructions: LocationPrompt.instructions)
                return try await session.respond(
                    to: LocationPrompt.prompt(context: context, facts: facts, priorities: settings.priorities)
                ).content
            } catch {
                try Task.checkCancellation()
            }
        }
        #endif
        return LocationTemplate.describe(context: context)
    }
}

/// "Describe my location", AI mode (T22): the context from Maps and the camera's latest
/// observation, said on the device under the T23 ranking and the T24 rules.
final class LocationNarrator: Sendable {
    /// A location answer is short (T24), a little longer than an answer to a question.
    static let policy = AskAIPolicy(maxSentences: 3, maxWords: 40)

    private let responder: any LocationResponding
    private let settings: AskAISettings
    private let policy: AskAIPolicy
    private let now: @Sendable () -> Date
    private let history = Mutex<[(sentence: String, at: Date)]>([])

    init(
        settings: AskAISettings = AskAISettings(),
        responder: (any LocationResponding)? = nil,
        policy: AskAIPolicy = LocationNarrator.policy,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.settings = settings
        self.responder = responder ?? OnDeviceLocationResponder(settings: settings)
        self.policy = policy
        self.now = now
    }

    /// `observation` is what the live pipeline last saw; `.empty` with the camera off.
    func describe(context: PlaceContext, observation: SceneObservation = .empty) async throws -> String {
        try Task.checkCancellation()
        var facts = ImageFacts()
        facts.detections = Array(observation.prioritizedDetections.prefix(8))
        facts.elevationHazards = observation.elevationHazards
        facts.text = observation.recognizedText
        // The street and landmarks are what the answer is about; naming them lets T23 rank
        // their sentences and keeps T24 from calling an answer about a known place "nothing
        // found". Without this a street sentence has no category and sinks to the end.
        facts.labels = [context.street].compactMap { $0 } + context.landmarks.map(\.name)

        guard !context.isEmpty else { return LocationTemplate.cannotTell }
        let raw = try await responder.answer(context: context, facts: facts)
        try Task.checkCancellation()

        let time = now()
        let result = history.withLock { history in
            history.removeAll { time.timeIntervalSince($0.at) > policy.repeatWindow }
            let result = policy.apply(
                raw, question: LocationPrompt.request, facts: facts,
                priorities: settings.priorities, recentlySaid: Set(history.map(\.sentence))
            )
            history += result.newlySaid.map { ($0, time) }
            return result
        }
        return result.answer
    }
}
