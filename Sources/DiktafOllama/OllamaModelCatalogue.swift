import Foundation

/// Whether Ollama is there, which models it has, and loading one ahead of time.
///
/// The counterpart of `WhisperModelCatalogue`, minus the download: Ollama fetches
/// its own models with `ollama pull`. Nothing here throws — "not running" is an answer.
public struct OllamaModelCatalogue: Sendable {
    private let baseURL: URL
    private let transport: any HTTPTransport

    public init(baseURL: URL = OllamaRefiner.defaultBaseURL) {
        self.init(baseURL: baseURL, transport: URLSessionTransport())
    }

    init(baseURL: URL, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// The model a stored name refers to: the name itself, or
    /// `OllamaRefiner.recommendedModel` when there is none.
    public static func model(named name: String?) -> String {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? OllamaRefiner.recommendedModel : name
    }

    /// Whether the server answers within a second: it is on this machine, so one
    /// that takes longer is as good as not running.
    public func isRunning() async -> Bool {
        do {
            let (_, response) = try await transport.send(
                request(path: "api/version", timeoutSeconds: 1))
            return (200..<300).contains(response.statusCode)
        } catch {
            return false
        }
    }

    /// The models it has, by the name a request takes: `qwen2.5-coder:7b`.
    /// Empty when it is not running.
    public func installedModels() async -> [String] {
        do {
            let (data, response) = try await transport.send(
                request(path: "api/tags", timeoutSeconds: 2))
            guard (200..<300).contains(response.statusCode) else { return [] }
            return (try JSONDecoder().decode(Tags.self, from: data).models ?? [])
                .compactMap(\.name)
        } catch {
            return []
        }
    }

    /// Loads the model into memory now, so the first dictation does not wait for
    /// it. Failures are ignored: this only saves time, and the dictation that
    /// needs the model reports anything wrong with it on its own.
    public func prepare(model: String?) async {
        let body = Prepare(model: Self.model(named: model), keep_alive: OllamaChatRequest.keepAlive)
        // A generate request with no prompt only loads the model.
        var request = request(path: "api/generate", timeoutSeconds: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        _ = try? await transport.send(request)
    }

    private func request(path: String, timeoutSeconds: Int) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        return request
    }

    private struct Tags: Decodable {
        struct Model: Decodable { let name: String? }
        let models: [Model]?
    }

    private struct Prepare: Encodable {
        let model: String
        let keep_alive: String
    }
}
