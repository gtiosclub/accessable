import Foundation

/// Matches signs the camera read to the buildings expected along the route (LAND-3).
///
/// A match is only a hint for speech: it never moves route progress, because one misread sign must not skip a turn.
/// Each building is matched at most once per trip, including across reroutes.
struct LandmarkMatcher {
    enum Event: Equatable, Sendable {
        /// A building beside the route, read near where the route passes it.
        case passing(RouteLandmark, spokenName: String, wasAnnounced: Bool)
        /// The destination's building, read near the end of the route.
        case destination(RouteLandmark, spokenName: String, wasAnnounced: Bool)
    }

    private(set) var landmarks: [RouteLandmark]
    private var matchedNames: Set<String> = []

    // signs are readable from about this far, and the building's closest point can be just behind the user
    private static let aheadWindow: Double = 60
    private static let behindWindow: Double = 25
    // the destination's sign confirms arrival from across a small plaza
    private static let destinationWindow: Double = 60
    // below this CV's own sign reader doesn't speak either
    private static let minimumConfidence: Float = 0.5

    init(landmarks: [RouteLandmark]) {
        self.landmarks = landmarks
    }

    /// A reroute changes where each building is along the route; ones already matched stay matched.
    mutating func replaceLandmarks(_ landmarks: [RouteLandmark]) {
        self.landmarks = landmarks
    }

    /// - Parameters:
    ///   - progress: metres along the route the user has reached.
    ///   - remaining: metres left to the destination.
    mutating func match(_ observation: LandmarkObservation, progress: Double, remaining: Double) -> Event? {
        guard observation.kind == .signText || observation.kind == .entrance,
              observation.confidence >= Self.minimumConfidence,
              let text = observation.text
        else { return nil }
        let signTokens = Self.tokens(text)
        guard !signTokens.isEmpty else { return nil }

        let candidates = landmarks.compactMap { landmark -> (RouteLandmark, name: String, words: Int, gap: Double)? in
            guard !matchedNames.contains(landmark.name), isInWindow(landmark, progress: progress, remaining: remaining)
            else { return nil }
            let matched = landmark.allNames.filter { Self.matches(signTokens, name: $0) }
            guard let best = matched.max(by: { Self.tokens($0).count < Self.tokens($1).count }) else { return nil }
            return (landmark, best, Self.tokens(best).count, abs(landmark.distanceAlongRoute - progress))
        }
        // "Library East" beats "Library" for a sign reading both; between equally good names the nearer building wins
        guard let (landmark, spokenName, _, _) = candidates.min(by: { ($1.words, $0.gap) < ($0.words, $1.gap) })
        else { return nil }
        matchedNames.insert(landmark.name)
        return landmark.isDestination
            ? .destination(landmark, spokenName: spokenName, wasAnnounced: observation.wasAnnounced)
            : .passing(landmark, spokenName: spokenName, wasAnnounced: observation.wasAnnounced)
    }

    private func isInWindow(_ landmark: RouteLandmark, progress: Double, remaining: Double) -> Bool {
        // "passing your destination" halfway along would only confuse, so the destination waits for the end
        if landmark.isDestination { return remaining <= Self.destinationWindow }
        return (progress - Self.behindWindow...progress + Self.aheadWindow).contains(landmark.distanceAlongRoute)
    }

    // MARK: - Text matching

    /// Whether the sign contains the name. Names of one or two words need every word; longer ones need three in four,
    /// since OCR often drops a word from a long plate. Words of five letters or more may be one OCR error off.
    static func matches(_ signTokens: [String], name: String) -> Bool {
        let nameTokens = tokens(name).filter { !ignoredWords.contains($0) }
        guard nameTokens.contains(where: { $0.count >= 3 }) else { return false }
        let found = nameTokens.filter { word in signTokens.contains { isSameWord($0, word) } }.count
        let needed = nameTokens.count <= 2 ? nameTokens.count : Int((Double(nameTokens.count) * 0.75).rounded(.up))
        return found >= needed
    }

    /// Lowercased words without accents or punctuation, with common sign abbreviations spelled out.
    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
            .split { !$0.isLetter && !$0.isNumber }
            .map { abbreviations[String($0)] ?? String($0) }
    }

    // words that names carry but signs often leave off
    private static let ignoredWords: Set<String> = ["the", "of", "and", "building"]
    private static let abbreviations = [
        "bldg": "building", "ctr": "center", "cntr": "center", "lib": "library", "univ": "university",
    ]

    private static func isSameWord(_ read: String, _ expected: String) -> Bool {
        if read == expected { return true }
        let allowed = expected.count >= 8 ? 2 : expected.count >= 5 ? 1 : 0
        return allowed > 0 && editDistance(read, expected, atMost: allowed) <= allowed
    }

    /// Levenshtein distance between non-empty words, stopping early once it must exceed `limit`.
    private static func editDistance(_ a: String, _ b: String, atMost limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= limit else { return limit + 1 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            if current.min() ?? 0 > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }
}
