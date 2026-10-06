import DiktafCore
import Foundation

/// Cleanup, done by a model Ollama serves on this machine.
///
/// The same job as `ClaudeRefiner`, an order of magnitude sooner once the model
/// is in memory — which is what `OllamaModelCatalogue.prepare(model:)` is for.
public struct OllamaRefiner: TextRefiner {
    /// What nil in the settings means. Measured on Turkish dictation against
    /// Claude haiku: close to it in quality at about a second rather than nine,
    /// where the 7–9B models left filler words in and renamed technical terms.
    public static let recommendedModel = "gemma4:12b"

    /// Where `ollama serve` listens unless told otherwise.
    public static let defaultBaseURL = URL(string: "http://localhost:11434")
        ?? URL(filePath: "/")

    private let baseURL: URL
    private let model: @Sendable () async -> String?
    private let timeoutSeconds: @Sendable () async -> Int
    private let transport: any HTTPTransport

    /// - Parameters:
    ///   - model: a name as `ollama list` prints it, or nil for `recommendedModel`.
    ///   - timeoutSeconds: past this the caller delivers the raw transcript.
    ///
    /// Both are asked at every dictation, as in `ClaudeRefiner`: a value read at
    /// construction is the one from before the user changed it.
    public init(
        baseURL: URL = OllamaRefiner.defaultBaseURL,
        model: @escaping @Sendable () async -> String?,
        timeoutSeconds: @escaping @Sendable () async -> Int
    ) {
        self.init(baseURL: baseURL, model: model, timeoutSeconds: timeoutSeconds,
                  transport: URLSessionTransport())
    }

    init(
        baseURL: URL,
        model: @escaping @Sendable () async -> String?,
        timeoutSeconds: @escaping @Sendable () async -> Int,
        transport: any HTTPTransport
    ) {
        self.baseURL = baseURL
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.transport = transport
    }

    public func refine(text: String, instruction: String) async throws -> String {
        let model = OllamaModelCatalogue.model(named: await model())
        let seconds = max(1, await timeoutSeconds())
        var body = OllamaChatRequest.cleanup(model: model, instruction: instruction, text: text)

        var (data, response) = try await send(body, seconds: seconds)

        // Some models and servers refuse the whole request over the field rather
        // than ignoring it, and a cleanup without it beats none.
        if response.statusCode == 400, body.think != nil,
           OllamaReply.explain(status: 400, body: data).lowercased().contains("think") {
            body.think = nil
            (data, response) = try await send(body, seconds: seconds)
        }

        guard (200..<300).contains(response.statusCode) else {
            let detail = OllamaReply.explain(status: response.statusCode, body: data)
            if Self.isMissingModel(detail) {
                throw RefinementFailure.agentUnavailable(
                    "Ollama'da \(model) adlı model yok; `ollama pull \(model)` çalıştırın")
            }
            throw RefinementFailure.agentFailed(detail)
        }

        let reply: OllamaReply
        do {
            reply = try JSONDecoder().decode(OllamaReply.self, from: data)
        } catch {
            throw RefinementFailure.agentFailed(
                "Ollama'nın yanıtı okunamadı: \(String(decoding: data.prefix(400), as: UTF8.self))")
        }
        if let error = reply.error, !error.isEmpty {
            throw RefinementFailure.agentFailed(error)
        }

        let cleaned = (reply.message?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw RefinementFailure.emptyReply }
        return cleaned
    }

    private func send(
        _ body: OllamaChatRequest,
        seconds: Int
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // An idle timeout rather than a total one, which is the same thing here:
        // with streaming off the server sends nothing until the reply is done.
        request.timeoutInterval = TimeInterval(seconds)
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw RefinementFailure.agentFailed(String(describing: error))
        }

        do {
            return try await transport.send(request)
        } catch let error as URLError {
            throw failure(for: error, seconds: seconds)
        }
    }

    private func failure(for error: URLError, seconds: Int) -> any Error {
        switch error.code {
        case .cancelled where Task.isCancelled:
            return CancellationError()
        case .timedOut:
            return RefinementFailure.timedOut(seconds: seconds)
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            return RefinementFailure.agentUnavailable(
                "Ollama \(baseURL.absoluteString) adresinde çalışmıyor")
        default:
            return RefinementFailure.agentFailed(error.localizedDescription)
        }
    }

    /// "model 'x' not found", with a 404. Matched on the words rather than the
    /// status, which any server answers an unknown path with.
    static func isMissingModel(_ detail: String) -> Bool {
        let detail = detail.lowercased()
        return detail.contains("model") && detail.contains("not found")
    }
}
