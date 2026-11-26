import Foundation
import os

private let log = Logger(subsystem: "AccessAble", category: "Search")

/// A Georgia Tech campus place with shorthand nicknames and a coordinate for direct resolution.
struct CampusNicknamePlace: Equatable, Sendable {
    let name: String
    let nicknames: [String]
    let coordinate: GeoCoordinate
    let address: String?

    var subtitle: String { address ?? "Georgia Tech" }

    var suggestion: SearchSuggestion {
        SearchSuggestion(title: name, subtitle: subtitle, coordinate: coordinate)
    }

    var destination: Destination {
        Destination(name: name, coordinate: coordinate, address: address)
    }

    var allNames: [String] { [name] + nicknames }
}

/// Maps Georgia Tech shorthand and nicknames to campus places before MapKit is queried,
/// and removes duplicate MapKit suggestions when combining results.
struct CampusNicknameDictionary: Sendable {
    let places: [CampusNicknamePlace]

    /// Loaded from `campus-nicknames.json` in the app bundle. Empty if missing or unreadable;
    /// search then falls back to MapKit alone, and the failure is logged.
    static let bundled = load(from: Bundle.main.url(forResource: "campus-nicknames", withExtension: "json"))

    /// The dictionary in the file at `url`, or an empty one, logged, when there is no file or it can't be read.
    static func load(from url: URL?) -> CampusNicknameDictionary {
        guard let url else {
            log.error("campus-nicknames.json is missing from the app bundle")
            return CampusNicknameDictionary(places: [])
        }
        do {
            return try decode(Data(contentsOf: url))
        } catch {
            log.error("Could not read campus-nicknames.json: \(error.localizedDescription, privacy: .public)")
            return CampusNicknameDictionary(places: [])
        }
    }

    init(places: [CampusNicknamePlace]) {
        self.places = places
    }

    static func decode(_ data: Data) throws -> CampusNicknameDictionary {
        let decoded = try JSONDecoder().decode(Export.self, from: data)
        let places = decoded.places.map {
            CampusNicknamePlace(
                name: $0.name,
                nicknames: $0.nicknames,
                coordinate: GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude),
                address: $0.address
            )
        }
        return CampusNicknameDictionary(places: places)
    }

    /// Matching places ordered from strongest match (exact nickname/name) to broadest (word match),
    /// ignoring case and punctuation.
    func matches(for query: String) -> [CampusNicknamePlace] {
        let normalizedQuery = Self.normalize(query)
        guard !normalizedQuery.compact.isEmpty else { return [] }

        var scored: [(rank: MatchRank, index: Int, place: CampusNicknamePlace)] = []
        for (index, place) in places.enumerated() {
            var bestRank: MatchRank?
            for candidate in place.allNames {
                guard let rank = Self.rank(query: normalizedQuery, against: Self.normalize(candidate)) else {
                    continue
                }
                if let current = bestRank {
                    if rank < current { bestRank = rank }
                } else {
                    bestRank = rank
                }
            }
            if let bestRank {
                scored.append((bestRank, index, place))
            }
        }

        scored.sort {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.index < $1.index
        }
        return scored.map(\.place)
    }

    /// Combines dictionary matches first with MapKit results, removing any MapKit result
    /// that duplicates a matched dictionary place or an earlier MapKit result.
    func merge(matches: [CampusNicknamePlace], mapKitResults: [SearchSuggestion]) -> [SearchSuggestion] {
        matches.map(\.suggestion) + deduplicate(mapKitResults, against: matches)
    }

    /// A MapKit result this close to a matched place, in metres, is taken to be the same place.
    static let duplicateDistance: Double = 50

    /// Filters out MapKit suggestions that duplicate any of `matchedPlaces` (by canonical name,
    /// nickname, case/punctuation-normalized campus variants, or a coordinate within
    /// `duplicateDistance`) as well as duplicate MapKit rows.
    func deduplicate(_ mapKitResults: [SearchSuggestion], against matchedPlaces: [CampusNicknamePlace]) -> [SearchSuggestion] {
        let matchedIDs = Set(matchedPlaces.map(\.suggestion.id))
        let matchedKeys = Set(
            matchedPlaces.flatMap(\.allNames)
                .map { Self.normalize($0).compact }
                .filter { !$0.isEmpty }
        )

        var seenIDs = Set<SearchSuggestion.ID>()
        return mapKitResults.filter { suggestion in
            guard !matchedIDs.contains(suggestion.id) else { return false }
            guard seenIDs.insert(suggestion.id).inserted else { return false }
            if let coordinate = suggestion.coordinate, matchedPlaces.contains(where: {
                GeoMath.distance(from: coordinate, to: $0.coordinate) <= Self.duplicateDistance
            }) {
                return false
            }
            return !Self.isDuplicateTitle(suggestion.title, matchingKeys: matchedKeys)
        }
    }

    // MARK: - Normalization & Ranking

    private enum MatchRank: Int, Comparable {
        case exact = 0
        case prefix = 1
        case word = 2

        static func < (lhs: MatchRank, rhs: MatchRank) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private struct NormalizedText {
        let compact: String
        let words: [String]
        var phrase: String { words.joined(separator: " ") }
    }

    /// Folds case and diacritics and removes punctuation. Periods and apostrophes join inside tokens
    /// (`"C.U.L.C."` -> `"culc"`, `"O'Keefe"` -> `"okeefe"`); other punctuation separates words.
    private static func normalize(_ text: String) -> NormalizedText {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var compact = ""
        var words: [String] = []
        var currentWord = ""

        for character in folded {
            if character.isLetter || character.isNumber {
                compact.append(character)
                currentWord.append(character)
            } else if character == "." || character == "'" || character == "’" {
                continue
            } else if !currentWord.isEmpty {
                words.append(currentWord)
                currentWord = ""
            }
        }
        if !currentWord.isEmpty {
            words.append(currentWord)
        }

        return NormalizedText(compact: compact, words: words)
    }

    private static func rank(query: NormalizedText, against candidate: NormalizedText) -> MatchRank? {
        guard !query.compact.isEmpty, !candidate.compact.isEmpty else { return nil }
        if candidate.compact == query.compact {
            return .exact
        }
        guard query.compact.count >= 2 else { return nil }
        if candidate.phrase.hasPrefix(query.phrase)
            || (query.compact.count >= 3 && candidate.compact.hasPrefix(query.compact)) {
            return .prefix
        }
        guard query.compact.count >= 3 else { return nil }
        if wordsMatchInOrder(query.words, in: candidate.words) {
            return .word
        }
        return nil
    }

    private static func wordsMatchInOrder(_ queryWords: [String], in candidateWords: [String]) -> Bool {
        guard !queryWords.isEmpty else { return false }
        var candidateIndex = 0
        for queryWord in queryWords {
            guard let match = candidateWords[candidateIndex...].firstIndex(where: { $0.hasPrefix(queryWord) }) else {
                return false
            }
            candidateIndex = match + 1
        }
        return true
    }

    private static func isDuplicateTitle(_ title: String, matchingKeys: Set<String>) -> Bool {
        let normalized = normalize(title)
        if matchingKeys.contains(normalized.compact) {
            return true
        }

        // Catch titles like "Clough Undergraduate Learning Commons (CULC)" or "John Lewis Student Center (Georgia Tech)".
        if let openParen = title.lastIndex(of: "("),
           let closeParen = title.lastIndex(of: ")"),
           openParen < closeParen {
            let base = String(title[..<openParen])
            let inside = String(title[title.index(after: openParen)..<closeParen])
            let baseCompact = normalize(base).compact
            let insideCompact = normalize(inside).compact
            if matchingKeys.contains(baseCompact),
               matchingKeys.contains(insideCompact) || campusTags.contains(insideCompact) {
                return true
            }
        }

        // Catch MapKit prefix/suffix variants like "Georgia Tech Student Center" or "GT Exhibition Hall".
        for stripped in strippedCampusAffixes(from: normalized.words) {
            if matchingKeys.contains(stripped) {
                return true
            }
        }

        return false
    }

    private static let campusTags: Set<String> = ["gt", "gatech", "georgiatech"]

    private static func strippedCampusAffixes(from words: [String]) -> [String] {
        var variants: [String] = []
        if words.starts(with: ["georgia", "tech"]), words.count > 2 {
            variants.append(words.dropFirst(2).joined())
        }
        if words.first == "gt", words.count > 1 {
            variants.append(words.dropFirst().joined())
        }
        if words.count > 3, Array(words.suffix(3)) == ["at", "georgia", "tech"] {
            variants.append(words.dropLast(3).joined())
        }
        if words.count > 2, Array(words.suffix(2)) == ["georgia", "tech"] {
            variants.append(words.dropLast(2).joined())
        }
        if words.count > 1, let last = words.last, campusTags.contains(last) {
            variants.append(words.dropLast().joined())
        }
        return variants
    }

    private struct Export: Decodable {
        let places: [Entry]
    }

    private struct Entry: Decodable {
        let name: String
        let nicknames: [String]
        let address: String?
        let latitude: Double
        let longitude: Double
    }
}
