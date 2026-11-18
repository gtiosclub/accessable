import Foundation
import os

private let log = Logger(subsystem: "AccessAble", category: "VoiceAgent")

/// Owner: User Interaction (3.1). Calls the Claude Messages API over HTTPS for the voice
/// agent. There is no official Anthropic SDK for Swift, so this posts JSON directly.
struct ClaudeMessagesClient: Sendable {
    static let model = "claude-opus-5-5"

    let apiKey: String
    var session: URLSession = .shared

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let maxRetries = 2

    struct ToolUse: Equatable, Sendable {
        let id: String
        let name: String
        let input: [String: JSONValue]
    }

    struct Response: Sendable {
        let stopReason: String?
        /// The assistant content blocks exactly as received, to append to the conversation.
        let content: [JSONValue]

        var text: String {
            content.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var toolUses: [ToolUse] {
            content.compactMap { block in
                guard block["type"]?.stringValue == "tool_use",
                      let id = block["id"]?.stringValue,
                      let name = block["name"]?.stringValue
                else { return nil }
                return ToolUse(id: id, name: name, input: block["input"]?.objectValue ?? [:])
            }
        }
    }

    enum Failure: Error, Equatable {
        case invalidKey
        case rateLimited
        case overloaded
        case badRequest(String)
        case server(Int)
        case offline
        case malformedResponse

        /// Safe to read aloud.
        var spokenMessage: String {
            switch self {
            case .invalidKey: "The Claude API key was rejected. Check it in Settings."
            case .rateLimited, .overloaded: "The assistant is busy right now. Please try again in a moment."
            case .offline: "I can't reach the assistant. Check your internet connection."
            case .badRequest, .server, .malformedResponse: "Sorry, something went wrong. Please try again."
            }
        }
    }

    /// One Messages API call. Retries rate limits, overloads and server errors twice.
    func send(messages: [JSONValue]) async throws -> Response {
        let body: JSONValue = [
            "model": .string(Self.model),
            "max_tokens": 16000,
            "system": .string(VoiceAgentTools.systemPrompt),
            "tools": .array(VoiceAgentTools.definitions),
            "messages": .array(messages),
            // Short spoken turns: low effort keeps the reply quick.
            "output_config": ["effort": "low"],
            // Caches the growing conversation prefix between turns.
            "cache_control": ["type": "ephemeral"],
            // If a safety classifier declines, the API retries on a fallback model in the same call.
            "fallbacks": "default",
        ]
        let encoder = JSONEncoder()
        // Stable key order keeps the request prefix byte-identical, so it can be cached.
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(body)

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        var attempt = 0
        while true {
            do {
                return try await sendOnce(request)
            } catch let failure as Failure where attempt < Self.maxRetries && failure.isRetryable {
                attempt += 1
                try await Task.sleep(for: .seconds(Double(attempt)))
            }
        }
    }

    private func sendOnce(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            log.error("Messages request failed: \(error.localizedDescription)")
            throw Failure.offline
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw Failure.invalidKey
        case 429:
            throw Failure.rateLimited
        case 529:
            throw Failure.overloaded
        case 400 ..< 500:
            let message = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]?["message"]?.stringValue
            log.error("Messages API \(http.statusCode): \(message ?? "no message", privacy: .public)")
            throw Failure.badRequest(message ?? "HTTP \(http.statusCode)")
        default:
            log.error("Messages API \(http.statusCode)")
            throw Failure.server(http.statusCode)
        }

        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let content = json["content"]?.arrayValue
        else { throw Failure.malformedResponse }
        return Response(stopReason: json["stop_reason"]?.stringValue, content: content)
    }
}

private extension ClaudeMessagesClient.Failure {
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .server: true
        default: false
        }
    }
}
