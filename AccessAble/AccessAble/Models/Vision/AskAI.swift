import CoreGraphics
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// "Ask AI" (T19): answers a natural-language question about one still image, entirely on
/// the device. Owner: Computer Vision (1.3 / task T19).
///
/// iOS 26's on-device language model reads text only, so the image never reaches it. It
/// gets `ImageFacts` instead: the objects, people and kerbs the live pipeline found (the
/// same ones "Describe my surroundings" reads, with direction and distance), plus text
/// and scene hints Vision reads from the still. It answers from that list alone, so it
/// cannot invent a room number or sign that was not read. Where Apple Intelligence is
/// unavailable (iPhone 12–14 Pro, or turned off), a template answers from the same list.
///
/// On demand only: one question, one image. It is not part of the obstacle pipeline and
/// is never used for warnings.
struct AskAI: Sendable {
    var extractor = ImageFactExtractor()
    var responder: any AskAIResponder = OnDeviceAskAIResponder()

    /// Vision blocks while it works, so it runs here rather than on the caller's actor or
    /// the concurrency pool, where several waiting calls can starve Vision's own work.
    private static let visionQueue = DispatchQueue(label: "AccessAble.AskAI.vision", qos: .userInitiated)

    /// Detections passed on to the model; the observation is already in priority order.
    var maxDetections = 8

    /// `observation` is what the live pipeline last saw around the still; `.empty` when
    /// there is no pipeline, as with a saved image.
    func answer(
        _ question: String,
        imageData: Data,
        observation: SceneObservation = .empty
    ) async throws -> AskAIResponse {
        let start = ContinuousClock.now

        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw AskAIError.emptyQuestion }
        let detections = Array(observation.prioritizedDetections.prefix(maxDetections))
        var facts = try await withCheckedThrowingContinuation { continuation in
            Self.visionQueue.async { [extractor] in
                continuation.resume(with: Result { try extractor.facts(from: imageData, colorsFor: detections) })
            }
        }
        facts.detections = detections
        facts.elevationHazards = observation.elevationHazards
        // The pipeline's people have distances; Vision's would only count them twice.
        if facts.detections.contains(where: { $0.label == "person" }) {
            facts.people = []
        }
        let answer = try await responder.answer(question, facts: facts)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw AskAIError.emptyAnswer }

        let elapsed = (ContinuousClock.now - start).components
        return AskAIResponse(
            answer: answer,
            latencyMilliseconds: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        )
    }
}

struct AskAIResponse: Equatable, Sendable {
    let answer: String
    /// From receiving the image to having the answer: Vision plus the model.
    let latencyMilliseconds: Double
}

enum AskAIError: LocalizedError, Equatable {
    case emptyQuestion
    case invalidImage
    case noCameraImage
    case emptyAnswer
    case modelFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyQuestion: "Ask a question about what the camera sees."
        case .invalidImage: "The camera image couldn't be read."
        case .noCameraImage: "No camera image is available. Start camera guidance and ask again."
        case .emptyAnswer: "Ask AI didn't come up with an answer."
        case .modelFailed(let reason): "Ask AI couldn't answer: \(reason)"
        }
    }
}

/// Answers a question from what was found in and around the image. The seam tests replace.
protocol AskAIResponder: Sendable {
    func answer(_ question: String, facts: ImageFacts) async throws -> String
}

/// The on-device model when Apple Intelligence is available, the template otherwise.
/// Checked per question, since the model can finish downloading or be turned off at any time.
struct OnDeviceAskAIResponder: AskAIResponder {
    func answer(_ question: String, facts: ImageFacts) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *), SystemLanguageModel.default.isAvailable {
            return try await FoundationModelsAskAIResponder().answer(question, facts: facts)
        }
        #endif
        return TemplateAskAIResponder().answer(question, facts: facts)
    }
}

#if canImport(FoundationModels)
/// Apple's on-device language model. A fresh session per question: questions are
/// independent, and nothing carries over between them.
@available(iOS 26, macOS 26, *)
struct FoundationModelsAskAIResponder: AskAIResponder {
    func answer(_ question: String, facts: ImageFacts) async throws -> String {
        let session = LanguageModelSession(instructions: AskAIPrompt.instructions)
        do {
            return try await session.respond(to: AskAIPrompt.prompt(question: question, facts: facts)).content
        } catch {
            throw AskAIError.modelFailed(error.localizedDescription)
        }
    }
}
#endif

/// What the on-device model is told. Kept to T19's needs: grounded, short, honest about
/// what it can't tell. Response policy and personalization are T23/T24.
enum AskAIPrompt {
    static let instructions = """
        You help a blind or low-vision person understand what their phone camera sees. \
        You cannot see the picture. You get a list of what on-device vision found: \
        objects, people and ground hazards with their direction and distance, \
        text and where it is, and what the scene probably contains. \
        Colours are rough estimates, so say an object looks a colour. \
        Answer the question in one or two short sentences using only that list. \
        If the list does not answer the question, say you can't tell from this picture. \
        Never guess room numbers, signs, directions or objects that are not in the list. \
        Never say that a path or a street crossing is safe.
        """

    static func prompt(question: String, facts: ImageFacts) -> String {
        var lines: [String] = []
        if facts.isEmpty {
            lines.append("Vision found nothing it could read or recognize in the picture.")
        }
        if !facts.elevationHazards.isEmpty || !facts.detections.isEmpty {
            lines.append("Detected around the user, most important first:")
            lines += facts.elevationHazards.map { "- \(SpokenPhrasing.describe($0))" }
            lines += facts.detections.map { detection in
                let color = facts.detectionColors[detection.id].map { " Main colour: \($0)." } ?? ""
                return "- \(SpokenPhrasing.describe(detection))\(color)"
            }
        }
        if !facts.text.isEmpty {
            lines.append("Text in the picture:")
            lines += facts.text.map { "- \"\($0.string)\", \(position(of: $0.boundingBox))" }
        }
        if !facts.labels.isEmpty {
            lines.append("Whole-picture guesses, no position: \(facts.labels.joined(separator: ", ")).")
        }
        if !facts.people.isEmpty {
            lines.append("People: \(facts.people.count), \(facts.people.map { position(of: $0) }.joined(separator: "; ")).")
        }
        lines.append("")
        lines.append("Question: \(question)")
        return lines.joined(separator: "\n")
    }

    /// Thirds of the upright picture, as "Describe my surroundings" (T18) words them, plus
    /// "high up" for signs near the top.
    static func position(of box: CGRect) -> String {
        let side = switch box.midX {
        case ..<0.33: "on your left"
        case ..<0.66: "ahead"
        default: "on your right"
        }
        return box.midY < 0.25 ? "\(side), high up" : side
    }
}

/// Answers without a language model, by matching the question's words against the facts.
struct TemplateAskAIResponder: AskAIResponder {
    func answer(_ question: String, facts: ImageFacts) -> String {
        var asked = Self.words(in: question)
        let asksColor = !asked.isDisjoint(with: Self.colorWords)
        asked.subtract(Self.colorWords)
        // A question with nothing specific in it ("What's in front of me?") gets the same
        // overview as "Describe my surroundings", or every object's colour if that was asked.
        if asked.isEmpty {
            let colors = facts.detections.compactMap { detection in
                facts.detectionColors[detection.id].map { "\(Self.capitalized(detection.label)) looks \($0)." }
            }
            if asksColor, !colors.isEmpty { return colors.prefix(3).joined(separator: " ") }
            if let overview = overview(of: facts) { return overview }
        }
        if !asked.isDisjoint(with: Self.personWords) {
            asked.insert("person")
        }
        // "Room 210" must not match a "Room 212" sign: numbers asked for must all be there.
        let numbers = asked.filter { $0.contains(where: \.isNumber) }

        var sentences = facts.elevationHazards
            .filter { !Self.words(in: SpokenPhrasing.name(of: $0.type)).isDisjoint(with: asked) }
            .map(SpokenPhrasing.describe)
        sentences += facts.detections
            .filter { !Self.words(in: $0.label).isDisjoint(with: asked) }
            .map { detection in
                let color = asksColor ? facts.detectionColors[detection.id].map { " It looks \($0)." } ?? "" : ""
                return SpokenPhrasing.describe(detection) + color
            }
        sentences += facts.text
            .filter { text in
                let read = Self.words(in: text.string)
                return numbers.isEmpty ? !read.isDisjoint(with: asked) : numbers.isSubset(of: read)
            }
            .map { "\"\($0.string)\" is \(AskAIPrompt.position(of: $0.boundingBox))." }
        sentences += facts.labels
            .filter { !Self.words(in: $0).isDisjoint(with: asked) }
            .map { "There seems to be a \($0) in view." }
        if !facts.people.isEmpty, !asked.isDisjoint(with: Self.personWords) {
            let count = facts.people.count == 1 ? "one person" : "\(facts.people.count) people"
            sentences.append("I can see \(count), \(facts.people.map { AskAIPrompt.position(of: $0) }.joined(separator: " and ")).")
        }
        if !sentences.isEmpty {
            return sentences.prefix(3).joined(separator: " ")
        }

        if asked.isEmpty { return "I can't tell that from this picture." }
        var visible = facts.detections.map(\.label) + facts.text.map { "\"\($0.string)\"" } + facts.labels
        visible = visible.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        guard !visible.isEmpty else { return "I can't tell that from this picture." }
        return "I can't tell that from this picture. I can see \(visible.prefix(3).joined(separator: ", "))."
    }

    /// "Describe my surroundings" (T18) over the facts, or nil when there is nothing it describes.
    private func overview(of facts: ImageFacts) -> String? {
        guard !facts.detections.isEmpty || !facts.elevationHazards.isEmpty || !facts.text.isEmpty else { return nil }
        return SceneDescriptionBuilder().describe(SceneObservation(
            detections: facts.detections,
            recognizedText: facts.text,
            elevationHazards: facts.elevationHazards
        ))
    }

    private static func capitalized(_ label: String) -> String {
        label.prefix(1).uppercased() + label.dropFirst()
    }

    private static let colorWords: Set<String> = ["color", "colour"]
    private static let personWords: Set<String> = ["person", "people", "someone", "anyone", "somebody", "anybody"]
    private static let ignoredWords: Set<String> = [
        "the", "where", "what", "which", "there", "any", "nearby", "this", "that", "front",
        "directly", "see", "can", "and", "for", "around", "surrounding", "describe", "here",
        "anything", "everything", "thing", "object", "near", "close", "how", "far", "away",
        "you", "your", "about", "tell", "look", "ahead", "are", "doe", "have", "they",
        "them", "these", "those", "its", "their",
    ]

    /// Lowercased words worth matching: three letters or more, or containing a digit
    /// ("210"), singular ("chairs" → "chair").
    static func words(in string: String) -> Set<String> {
        Set(string.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map { word in word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : String(word) }
            .filter { ($0.count >= 3 || $0.contains(where: \.isNumber)) && !ignoredWords.contains($0) })
    }
}
