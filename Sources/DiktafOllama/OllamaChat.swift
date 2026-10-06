import Foundation

/// The body of one `/api/chat` request, as a value for the reason
/// `ClaudeInvocation` is one: the exact request is something a test can assert on.
struct OllamaChatRequest: Encodable, Sendable, Equatable {
    struct Message: Encodable, Sendable, Equatable {
        let role: String
        let content: String
    }

    struct Options: Encodable, Sendable, Equatable {
        let temperature: Double
    }

    /// How long the model stays loaded after the last request. Ollama's default
    /// is five minutes, after which a dictation pays seconds for a cold load.
    static let keepAlive = "30m"

    let model: String
    let messages: [Message]
    let stream: Bool
    /// Off: reasoning first spends seconds on a sentence that needed none. Nil
    /// leaves the field out, for the models that refuse it.
    var think: Bool?
    let keep_alive: String
    let options: Options

    /// The rules as the system message and the transcript as the user's, with no
    /// randomness: the same dictation should come back the same way twice.
    static func cleanup(model: String, instruction: String, text: String) -> OllamaChatRequest {
        OllamaChatRequest(
            model: model,
            messages: [
                Message(role: "system", content: instruction),
                Message(role: "user", content: text),
            ],
            stream: false,
            think: false,
            keep_alive: keepAlive,
            options: Options(temperature: 0)
        )
    }
}

/// What came back from `/api/chat`, or from any endpoint that refused. Every
/// field optional, as in `ClaudeOutput`: it is another program's format.
struct OllamaReply: Decodable, Sendable {
    struct Message: Decodable, Sendable {
        let content: String?
    }

    let message: Message?
    /// Ollama's account of a refusal, sent with every error status.
    let error: String?

    /// The server's own words, else the body, and the status only when it said
    /// nothing — an error message beats a number.
    static func explain(status: Int, body: Data) -> String {
        if let reply = try? JSONDecoder().decode(OllamaReply.self, from: body),
           let error = reply.error?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            return error
        }
        let text = String(decoding: body, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return String(text.prefix(400)) }
        return "Ollama HTTP \(status) ile yanıt verdi"
    }
}
