import Foundation

/// A control on screen that the voice agent can operate, as the agent sees it. Views opt in
/// with the `.agentButton` / `.agentTextField` / … modifiers; the registry turns what they
/// register into these snapshots.
struct AgentControl: Equatable, Sendable {
    enum Kind: String, Sendable {
        case button
        case textField = "text field"
        case toggle
        case slider
        case choice
    }

    /// Short id like "c12", stable while the control stays on screen.
    var id: String
    var kind: Kind
    var label: String
    var hint: String?
    /// Text field contents, "on"/"off", the slider position, or the selected choice.
    var value: String?
    /// For `.choice`: the options that can be picked. For `.slider`: empty.
    var options: [String] = []
    /// For `.slider`: the allowed range.
    var range: ClosedRange<Double>?
    var isEnabled = true
    /// Shown as "(selected)" for tabs, chips and checkmarked rows.
    var isSelected = false
    /// Acting on it waits for the user to say yes.
    var needsConfirmation = false

    /// One line of the screen listing sent to the model.
    var promptLine: String {
        var line = "- \(id) \(kind.rawValue) \"\(label)\""
        if let value {
            line += kind == .textField ? ", text: \"\(value)\"" : ", value: \(value)"
        }
        if let range {
            line += ", range \(range.lowerBound.formatted())–\(range.upperBound.formatted())"
        }
        if !options.isEmpty {
            line += ", options: " + options.map { "\"\($0)\"" }.joined(separator: ", ")
        }
        if isSelected { line += " (selected)" }
        if !isEnabled { line += " (disabled)" }
        if let hint, !hint.isEmpty { line += " — \(hint)" }
        return line
    }
}

/// Screens the agent can jump to without a control on the current screen.
enum AgentDestination: String, CaseIterable, Sendable {
    case back
    case home
    case search
    case settings
    case callHelp = "call_help"
    case camera
}

/// One tool call from the model, parsed and validated.
enum AgentAction: Equatable, Sendable {
    case press(controlID: String)
    case typeText(controlID: String, text: String, submit: Bool)
    case setToggle(controlID: String, isOn: Bool)
    case setValue(controlID: String, value: String)
    case navigate(AgentDestination)
    case describeSurroundings
    case whereAmI
    case repeatLastAnnouncement
    case lookWithCamera(question: String)

    enum ParseError: Error, Equatable {
        case unknownTool(String)
        case missingField(String)
        case invalidValue(String)

        /// Sent back to the model as an error tool result.
        var message: String {
            switch self {
            case .unknownTool(let name): "There is no tool named \(name)."
            case .missingField(let field): "The \(field) field is missing."
            case .invalidValue(let detail): detail
            }
        }
    }

    /// Validates a tool call. The tools are declared `strict`, but the inputs are checked
    /// again here: whatever the model sends, nothing unexpected reaches the UI.
    static func parse(name: String, input: [String: JSONValue]) -> Result<AgentAction, ParseError> {
        func string(_ key: String) -> Result<String, ParseError> {
            guard let value = input[key]?.stringValue else { return .failure(.missingField(key)) }
            return .success(value)
        }
        func bool(_ key: String) -> Result<Bool, ParseError> {
            guard let value = input[key]?.boolValue else { return .failure(.missingField(key)) }
            return .success(value)
        }

        do {
            switch name {
            case VoiceAgentTools.press:
                return .success(.press(controlID: try string("control_id").get()))
            case VoiceAgentTools.typeText:
                return .success(.typeText(
                    controlID: try string("control_id").get(),
                    text: try string("text").get(),
                    submit: try bool("submit").get()
                ))
            case VoiceAgentTools.setToggle:
                return .success(.setToggle(controlID: try string("control_id").get(), isOn: try bool("on").get()))
            case VoiceAgentTools.setValue:
                return .success(.setValue(controlID: try string("control_id").get(), value: try string("value").get()))
            case VoiceAgentTools.navigate:
                let raw = try string("destination").get()
                guard let destination = AgentDestination(rawValue: raw) else {
                    return .failure(.invalidValue("Unknown destination \(raw)."))
                }
                return .success(.navigate(destination))
            case VoiceAgentTools.describeSurroundings:
                return .success(.describeSurroundings)
            case VoiceAgentTools.whereAmI:
                return .success(.whereAmI)
            case VoiceAgentTools.repeatLast:
                return .success(.repeatLastAnnouncement)
            case VoiceAgentTools.lookWithCamera:
                let question = try string("question").get().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !question.isEmpty else { return .failure(.invalidValue("The question is empty.")) }
                return .success(.lookWithCamera(question: question))
            default:
                return .failure(.unknownTool(name))
            }
        } catch {
            return .failure(error)
        }
    }
}

/// What the user said while the agent was waiting for a yes or no.
enum ConfirmationReply: Equatable, Sendable {
    case yes
    case no
    /// Anything else: treated as a new request, and the pending action is dropped.
    case other

    private static let yesPhrases: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "do it", "go ahead", "confirm",
        "yes please", "please do", "correct", "that's right", "affirmative",
    ]
    private static let noPhrases: Set<String> = [
        "no", "nope", "nah", "cancel", "don't", "do not", "stop", "never mind", "nevermind",
        "no thanks", "no thank you", "don't do it",
    ]

    init(_ text: String) {
        let words = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        // A long sentence that happens to start with "yes" is a new request, not an answer.
        guard !words.isEmpty, words.count <= 4 else {
            self = .other
            return
        }
        let phrase = words.joined(separator: " ")
        let firstTwo = words.prefix(2).joined(separator: " ")
        if Self.noPhrases.contains(phrase) || Self.noPhrases.contains(firstTwo) || Self.noPhrases.contains(words[0]) {
            self = .no
        } else if Self.yesPhrases.contains(phrase) || Self.yesPhrases.contains(firstTwo) || Self.yesPhrases.contains(words[0]) {
            self = .yes
        } else {
            self = .other
        }
    }
}
