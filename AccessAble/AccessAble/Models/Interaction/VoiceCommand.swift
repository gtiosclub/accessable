import Foundation
 
/// Produced by a `CommandInterpreting` service from typed (later: spoken) text.
enum VoiceCommand: Equatable, Sendable {
    case describeSurroundings
    case whereAmI
    case repeatLast
    case pauseTrip
    case resumeTrip
    case endTrip
    /// A general question to answer in words.
    case ask(String)
    /// Nothing matched. Carries the original text for logging.
    case unknown(String)
}
 
/// Why a command or question couldn't be handled. `spokenMessage` is safe to read aloud.
enum CommandError: Error, Sendable {
    case modelUnavailable(reason: String)
    case refused
    case failed
 
    var spokenMessage: String {
        switch self {
        case .modelUnavailable(let reason): reason
        case .refused: "Sorry, I can't help with that."
        case .failed: "Sorry, I couldn't answer that. Please try again."
        }
    }
}
