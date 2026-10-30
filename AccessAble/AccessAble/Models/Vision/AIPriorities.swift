import Foundation
import Synchronization

// T23: Ask AI answers in the order the user cares about. The user ranks the kinds of
// information below in Settings; the on-device model is asked to answer in that order and
// the answer's sentences are reordered to match. Close hazards still come first whatever
// the order (T24).

/// A kind of information an Ask AI answer can contain.
enum AIInfoCategory: String, Codable, CaseIterable, Sendable {
    case hazards
    case navigation
    case people
    case signsText
    case landmarks

    var displayName: String {
        switch self {
        case .hazards: "Hazards"
        case .navigation: "Navigation"
        case .people: "People"
        case .signsText: "Signs and text"
        case .landmarks: "Landmarks"
        }
    }
}

/// The user's ranking of `AIInfoCategory`, most important first. Always holds every
/// category exactly once, so a ranking saved by an older build still works.
struct AIPriorities: Codable, Hashable, Sendable {
    private(set) var order: [AIInfoCategory]

    init(order: [AIInfoCategory]) {
        var seen = Set<AIInfoCategory>()
        self.order = (order + AIInfoCategory.allCases).filter { seen.insert($0).inserted }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown names (a category removed in a later build) are dropped, not fatal.
        let names = try container.decode([String].self, forKey: .order)
        self.init(order: names.compactMap(AIInfoCategory.init(rawValue:)))
    }

    static let `default` = AIPriorities(order: [.hazards, .navigation, .people, .signsText, .landmarks])

    /// Moves `category` up (negative) or down (positive) by `offset` places.
    mutating func move(_ category: AIInfoCategory, by offset: Int) {
        guard let from = order.firstIndex(of: category) else { return }
        let to = min(max(from + offset, 0), order.count - 1)
        order.remove(at: from)
        order.insert(category, at: to)
    }

    func rank(of category: AIInfoCategory) -> Int {
        order.firstIndex(of: category) ?? order.count
    }

    /// The categories a sentence talks about, judged from the facts the answer came from.
    static func categories(of sentence: String, facts: ImageFacts) -> Set<AIInfoCategory> {
        let text = AskAIPolicy.normalized(sentence)
        let words = Set(text.split(separator: " ").map(String.init))
        func mentions(_ phrase: String) -> Bool {
            let phrase = AskAIPolicy.normalized(phrase)
            return !phrase.isEmpty && " \(text) ".contains(" \(phrase) ")
        }
        var found = Set<AIInfoCategory>()

        let hazardLabels = facts.detections.filter { $0.isHazard && $0.label != "person" }.map(\.label)
        if !words.isDisjoint(with: ["drop", "step", "steps", "kerb", "curb", "stair", "stairs", "uneven"])
            || hazardLabels.contains(where: mentions) {
            found.insert(.hazards)
        }
        if !words.isDisjoint(with: ["person", "people", "someone", "somebody", "man", "woman", "child", "crowd"]) {
            found.insert(.people)
        }
        if sentence.contains("\"") || !words.isDisjoint(with: ["sign", "signs", "says", "reads", "text", "written"])
            || facts.text.map(\.string).contains(where: mentions) {
            found.insert(.signsText)
        }
        if !words.isDisjoint(with: ["turn", "street", "road", "route", "north", "south", "east", "west", "heading", "destination", "block"]) {
            found.insert(.navigation)
        }
        if facts.labels.contains(where: mentions) || !words.isDisjoint(with: ["building", "landmark", "entrance"]) {
            found.insert(.landmarks)
        }
        return found
    }

    /// `sentences` reordered by their most important category, keeping the original order
    /// within a rank. A sentence about none ("It looks red.") stays with the one before it;
    /// one at the start goes after everything ranked.
    func ordered(_ sentences: [String], facts: ImageFacts) -> [String] {
        var ranks: [Int] = []
        for sentence in sentences {
            let categories = Self.categories(of: sentence, facts: facts)
            if let best = categories.map(rank(of:)).min() {
                ranks.append(best)
            } else {
                ranks.append(ranks.last ?? order.count)
            }
        }
        return zip(sentences, ranks).enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }
            .map(\.element.0)
    }
}

/// Where Ask AI reads the user's current ranking. The app updates it whenever the
/// profile changes; the responder reads it per question.
final class AskAISettings: Sendable {
    private let state = Mutex(AIPriorities.default)

    init(priorities: AIPriorities = .default) {
        state.withLock { $0 = priorities }
    }

    var priorities: AIPriorities {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}
