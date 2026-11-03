import Foundation
import Synchronization
#if canImport(FoundationModels)
import FoundationModels
#endif

// T24: what Ask AI is allowed to say. Short answers, honest when unsure, never that a
// street is safe to cross, no repeating itself, urgent hazards first.
//
// The rules sit in two places. The model is told them (`AskAIRules.instructions`), and
// every answer — the model's or the template's — goes through `AskAIPolicy` afterwards,
// because a small on-device model doesn't always follow instructions.

/// Answers with the T24 rules applied. Wraps the on-device model (or the template where
/// Apple Intelligence is unavailable) and keeps what it said recently, so a repeated
/// question gets "nothing new" instead of the same sentences again.
final class RuledAskAIResponder: AskAIResponder {
    private let model: any AskAIResponder
    private let policy: AskAIPolicy
    private let now: @Sendable () -> Date
    private let history = Mutex<[(sentence: String, at: Date)]>([])

    init(
        model: any AskAIResponder = RuledOnDeviceResponder(),
        policy: AskAIPolicy = AskAIPolicy(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.model = model
        self.policy = policy
        self.now = now
    }

    func answer(_ question: String, facts: ImageFacts) async throws -> String {
        let raw = try await model.answer(question, facts: facts)
        let time = now()
        return history.withLock { history in
            history.removeAll { time.timeIntervalSince($0.at) > policy.repeatWindow }
            let result = policy.apply(raw, question: question, facts: facts, recentlySaid: Set(history.map(\.sentence)))
            history += result.newlySaid.map { ($0, time) }
            return result.answer
        }
    }
}

/// The rules applied to an answer after it is generated. Pure, so each rule is testable.
struct AskAIPolicy: Sendable {
    /// Sentences of answer content kept, not counting a hazard warning or crossing caveat.
    var maxSentences = 2
    /// Words of answer content kept; whole sentences are dropped to fit, never cut mid-way.
    var maxWords = 40
    /// How long a sentence counts as already said.
    var repeatWindow: TimeInterval = 30
    /// Hazards this close are mentioned first if the answer doesn't mention them.
    var urgentHazardDistance: Double = 2
    var urgentObstacleDistance: Double = 1.5

    static let cannotTell = "I can't tell from this picture."
    static let crossingCaveat = "I can't tell if it's safe to cross."
    /// Prefixes a short repeat when everything in the answer was said moments ago: the
    /// user may have missed it, so they still get the gist, once.
    static let sameAsBefore = "Same as before:"

    struct Result: Equatable {
        let answer: String
        /// Normalized content sentences spoken this time, for the repeat check.
        let newlySaid: [String]
    }

    /// `recentlySaid` holds normalized sentences (see `normalized(_:)`) from recent answers.
    func apply(_ answer: String, question: String, facts: ImageFacts, recentlySaid: Set<String> = []) -> Result {
        let asksAboutCrossing = Self.asksAboutCrossing(question)

        // Nothing was found, so anything the model says beyond that is invented.
        guard !facts.isEmpty else {
            return Result(answer: asksAboutCrossing ? "\(Self.crossingCaveat) \(Self.cannotTell)" : Self.cannotTell, newlySaid: [])
        }

        let allowed = Self.sentences(in: answer).filter { !Self.claimsSafety($0) }
        let content = fit(allowed.filter { !recentlySaid.contains(Self.normalized($0)) })

        var spoken: [String] = []
        if let hazard = urgentHazard(in: facts, notMentionedIn: answer) {
            spoken.append(hazard)
        }
        if asksAboutCrossing {
            spoken.append(Self.crossingCaveat)
        }
        if !content.isEmpty {
            spoken += content
        } else if let first = allowed.first {
            spoken.append("\(Self.sameAsBefore) \(first)")
        } else if spoken.isEmpty {
            spoken.append(Self.cannotTell)
        }
        return Result(answer: spoken.joined(separator: " "), newlySaid: content.map(Self.normalized))
    }

    /// The first sentences that fit the sentence and word limits; always at least one.
    private func fit(_ sentences: [String]) -> [String] {
        var kept: [String] = []
        var words = 0
        for sentence in sentences.prefix(maxSentences) {
            let count = sentence.split(separator: " ").count
            if !kept.isEmpty && words + count > maxWords { break }
            kept.append(sentence)
            words += count
        }
        return kept
    }

    /// The nearest close hazard the answer leaves out, as a sentence. Drop-offs and steps
    /// first, then obstacles. Safety repeats: this is never suppressed as "already said".
    private func urgentHazard(in facts: ImageFacts, notMentionedIn answer: String) -> String? {
        let spoken = answer.lowercased()
        let ground = facts.elevationHazards
            .filter { $0.type != .unknown && Double($0.distance) <= urgentHazardDistance }
            .min { $0.distance < $1.distance }
        if let ground {
            let words = ground.type == .dropOff ? ["drop"] : ["step", "kerb", "curb", "stair"]
            return words.contains(where: spoken.contains) ? nil : SpokenPhrasing.describe(ground)
        }
        let obstacle = facts.detections
            .filter { $0.isHazard && ($0.distance ?? .infinity) <= urgentObstacleDistance }
            .min { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }
        if let obstacle, !spoken.contains(obstacle.label.lowercased()) {
            return SpokenPhrasing.describe(obstacle)
        }
        return nil
    }

    // MARK: - Text rules

    static func asksAboutCrossing(_ question: String) -> Bool {
        let words = Set(question.lowercased().split { !$0.isLetter }.map(String.init))
        return !words.isDisjoint(with: ["cross", "crossing", "crosswalk", "crosswalks", "crossings"])
            || (words.contains("safe") && !words.isDisjoint(with: ["street", "road", "traffic", "go", "walk"]))
    }

    /// True for a sentence telling the user something is safe or clear to cross or walk.
    /// A negated sentence ("I can't tell if it's safe to cross") is not a claim.
    static func claimsSafety(_ sentence: String) -> Bool {
        let text = sentence.lowercased().replacingOccurrences(of: "’", with: "'")
        let negations = ["not ", "n't", "never", "cannot", "unable", "unsure"]
        if negations.contains(where: text.contains) { return false }
        let claims = [
            #"\bsafe to (cross|go|walk|proceed)"#,
            #"\b(clear|okay|ok|fine|good) to (cross|go|walk|proceed)"#,
            #"\byou (can|may|could|should) (now )?(cross|go ahead|proceed|walk across)"#,
            #"\b(it'?s|it is|looks|seems|appears) (to be )?(safe|clear)\b"#,
            #"\b(path|way|street|road|crossing|crosswalk|coast) (is|looks|seems) (clear|safe)"#,
        ]
        return claims.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Splits after ".", "!" or "?" followed by a space, so "2.5 metres" stays whole.
    /// Every sentence comes back ending in punctuation.
    static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character.isWhitespace, let previous, ".!?".contains(previous) {
                sentences.append(current)
                current = ""
            } else if !(current.isEmpty && character.isWhitespace) {
                current.append(character)
            }
            previous = character
        }
        sentences.append(current)
        return sentences
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.contains(where: \.isLetter) }
            .map { ".!?".contains($0.last!) ? $0 : $0 + "." }
    }

    /// Lowercased letters, digits and single spaces, for comparing sentences.
    static func normalized(_ sentence: String) -> String {
        sentence.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }
}

/// What the on-device model is told under T24. Replaces T19's instructions for answers
/// that go through `RuledAskAIResponder`; the fact list is T19's `AskAIPrompt.prompt`.
enum AskAIRules {
    static let instructions = """
        You help a blind or low-vision person understand what their phone camera sees. \
        You cannot see the picture. You get a list of what on-device vision found: \
        objects, people and ground hazards with their direction and distance, \
        text and where it is, and what the scene probably contains.
        Rules:
        - Answer in one or two short sentences, under 30 words, using only that list.
        - If a hazard is close ahead, mention it first.
        - If the list does not answer the question, say you can't tell from this picture. \
        Never guess room numbers, signs, directions or objects that are not in the list.
        - Items marked uncertain, and colours, are estimates: say an object might be there, \
        or looks a colour.
        - Never say a street, crossing or path is safe or clear, or that the user can cross. \
        You cannot judge traffic.
        - Don't repeat yourself.
        """

    /// Detections below this are passed to the model as uncertain.
    static let uncertainBelow: Float = 0.7

    static func prompt(question: String, facts: ImageFacts) -> String {
        let uncertain = facts.detections
            .filter { $0.origin != .geometric && $0.confidence < uncertainBelow }
            .map(\.label)
        let base = AskAIPrompt.prompt(question: question, facts: facts)
        guard !uncertain.isEmpty else { return base }
        let unique = uncertain.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return "Uncertain detections, say they might be there: \(unique.joined(separator: ", ")).\n" + base
    }
}

/// The on-device model with the T24 instructions; the T19 template where Apple
/// Intelligence is unavailable or the model fails.
struct RuledOnDeviceResponder: AskAIResponder {
    func answer(_ question: String, facts: ImageFacts) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *), SystemLanguageModel.default.isAvailable {
            do {
                let session = LanguageModelSession(instructions: AskAIRules.instructions)
                return try await session.respond(to: AskAIRules.prompt(question: question, facts: facts)).content
            } catch {
                try Task.checkCancellation()
            }
        }
        #endif
        return TemplateAskAIResponder().answer(question, facts: facts)
    }
}
