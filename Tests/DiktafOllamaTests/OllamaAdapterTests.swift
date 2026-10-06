import DiktafCore
import Foundation
import Synchronization
import Testing
@testable import DiktafOllama

/// Replays recorded answers and remembers what it was asked.
///
/// No server is reached by these tests: what is worth testing is what goes into
/// the request and what each answer turns into, and both are deterministic.
final class StubTransport: HTTPTransport {
    enum Answer: Sendable {
        case reply(status: Int, body: String)
        case failure(URLError)
        /// Waits the way a slow server does, and fails the way URLSession does
        /// when the task waiting on it is cancelled.
        case hang
    }

    private let answers: Mutex<[Answer]>
    private let seen = Mutex<[URLRequest]>([])

    /// Each request takes the next answer; the last one is repeated.
    init(_ answers: Answer...) { self.answers = Mutex(answers) }

    var requests: [URLRequest] { seen.withLock { $0 } }
    var last: URLRequest? { requests.last }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        seen.withLock { $0.append(request) }
        let answer = answers.withLock { $0.count > 1 ? $0.removeFirst() : $0.first }

        switch answer {
        case .reply(let status, let body):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            else { throw URLError(.badURL) }
            return (Data(body.utf8), response)
        case .failure(let error):
            throw error
        case .hang:
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                throw URLError(.cancelled)
            }
            throw URLError(.timedOut)
        case nil:
            throw URLError(.unknown)
        }
    }
}

/// Real output, captured from `POST /api/chat` against Ollama 0.35.1 with
/// qwen2.5-coder:7b while this was being written.
private let recordedReply = """
{"model":"qwen2.5-coder:7b","created_at":"2026-10-06T14:20:07.086Z",\
"message":{"role":"assistant","content":"We should ship this on Thursday."},\
"done":true,"done_reason":"stop","total_duration":2990337125,\
"load_duration":2552520000,"prompt_eval_count":40,"eval_count":8}
"""

/// What the same server says when asked to think with a model that cannot.
private let refusesThinking = #"{"error":"\"qwen2.5-coder:7b\" does not support thinking"}"#

private func body(of request: URLRequest?) throws -> [String: Any] {
    let data = try #require(request?.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: -

@Suite("Ollama refiner")
struct OllamaRefinerTests {

    private func refiner(
        _ transport: StubTransport,
        model: String? = "qwen2.5-coder:7b",
        timeoutSeconds: Int = 20
    ) -> OllamaRefiner {
        OllamaRefiner(baseURL: OllamaRefiner.defaultBaseURL,
                      model: { model }, timeoutSeconds: { timeoutSeconds },
                      transport: transport)
    }

    @Test("the request is a non-streaming chat with the rules first and the transcript second")
    func buildsTheRequest() async throws {
        let transport = StubTransport(.reply(status: 200, body: recordedReply))

        _ = try await refiner(transport)
            .refine(text: "so um we should ship this", instruction: "Clean this up.")

        let request = try #require(transport.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://localhost:11434/api/chat")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 20)

        let json = try body(of: request)
        #expect(json["model"] as? String == "qwen2.5-coder:7b")
        #expect(json["stream"] as? Bool == false)
        #expect(json["think"] as? Bool == false)
        #expect(json["keep_alive"] as? String == "30m")
        #expect((json["options"] as? [String: Any])?["temperature"] as? Double == 0)

        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [
            ["role": "system", "content": "Clean this up."],
            ["role": "user", "content": "so um we should ship this"],
        ])
    }

    @Test("the cleaned text comes back trimmed")
    func returnsTrimmedContent() async throws {
        let padded = #"{"message":{"role":"assistant","content":"\n  We ship on Thursday.  \n"}}"#

        #expect(try await refiner(StubTransport(.reply(status: 200, body: padded)))
            .refine(text: "x", instruction: "rules") == "We ship on Thursday.")
        #expect(try await refiner(StubTransport(.reply(status: 200, body: recordedReply)))
            .refine(text: "x", instruction: "rules") == "We should ship this on Thursday.")
    }

    @Test("no model in the settings means the recommended one", arguments: [nil, "", "  "])
    func fallsBackToTheRecommendedModel(_ model: String?) async throws {
        let transport = StubTransport(.reply(status: 200, body: recordedReply))

        _ = try await refiner(transport, model: model).refine(text: "x", instruction: "rules")

        #expect(try body(of: transport.last)["model"] as? String == OllamaRefiner.recommendedModel)
        #expect(OllamaRefiner.recommendedModel == "gemma4:12b")
    }

    /// Both are settings, and this object lives as long as the application.
    @Test("the model and the deadline are asked at every cleanup, not once")
    func readsSettingsPerCall() async throws {
        let current = Mutex<(model: String, seconds: Int)>(("first:1b", 5))
        let transport = StubTransport(.reply(status: 200, body: recordedReply))
        let refiner = OllamaRefiner(
            baseURL: OllamaRefiner.defaultBaseURL,
            model: { current.withLock { $0.model } },
            timeoutSeconds: { current.withLock { $0.seconds } },
            transport: transport)

        _ = try await refiner.refine(text: "x", instruction: "rules")
        current.withLock { $0 = ("second:3b", 45) }
        _ = try await refiner.refine(text: "x", instruction: "rules")

        #expect(try transport.requests.map { try body(of: $0)["model"] as? String }
            == ["first:1b", "second:3b"])
        #expect(transport.requests.map(\.timeoutInterval) == [5, 45])
    }

    @Test("a timeout of zero is still a timeout of some length")
    func refusesAZeroDeadline() async throws {
        let transport = StubTransport(.reply(status: 200, body: recordedReply))

        _ = try await refiner(transport, timeoutSeconds: 0).refine(text: "x", instruction: "rules")

        #expect(transport.last?.timeoutInterval == 1)
    }

    @Test("an empty reply is not a cleaned-up transcript", arguments: [
        #"{"message":{"role":"assistant","content":""}}"#,
        #"{"message":{"role":"assistant","content":"  \n"}}"#,
        #"{"done":true}"#,
    ])
    func rejectsEmptyReplies(_ json: String) async {
        await #expect(throws: RefinementFailure.emptyReply) {
            try await refiner(StubTransport(.reply(status: 200, body: json)))
                .refine(text: "x", instruction: "rules")
        }
    }

    /// The answer is to start Ollama, not to wait for it, so it is worth saying
    /// as unavailable rather than as a failure.
    @Test("a server that is not there is unavailable", arguments: [
        URLError.Code.cannotConnectToHost, .cannotFindHost,
    ])
    func reportsAServerThatIsNotRunning(_ code: URLError.Code) async {
        await #expect(throws: RefinementFailure.agentUnavailable(
            "Ollama http://localhost:11434 adresinde çalışmıyor")) {
            try await refiner(StubTransport(.failure(URLError(code))))
                .refine(text: "x", instruction: "rules")
        }
    }

    @Test("a model the server does not have says how to get it", arguments: [
        (404, #"{"error":"model 'llama9:1b' not found"}"#),
        (404, #"{"error":"model \"llama9:1b\" not found, try pulling it first"}"#),
    ])
    func reportsAMissingModel(_ status: Int, _ json: String) async {
        await #expect(throws: RefinementFailure.agentUnavailable(
            "Ollama'da llama9:1b adlı model yok; `ollama pull llama9:1b` çalıştırın")) {
            try await refiner(StubTransport(.reply(status: status, body: json)), model: "llama9:1b")
                .refine(text: "x", instruction: "rules")
        }
    }

    @Test("any other refusal carries the server's own words", arguments: [
        (500, #"{"error":"llama runner process has terminated: signal: killed"}"#,
         "llama runner process has terminated: signal: killed"),
        (404, "404 page not found", "404 page not found"),
        (502, "", "Ollama HTTP 502 ile yanıt verdi"),
    ])
    func reportsOtherHTTPErrors(_ status: Int, _ body: String, _ expected: String) async {
        await #expect(throws: RefinementFailure.agentFailed(expected)) {
            try await refiner(StubTransport(.reply(status: status, body: body)))
                .refine(text: "x", instruction: "rules")
        }
    }

    @Test("a model that cannot think is asked again without the field")
    func retriesWithoutThink() async throws {
        let transport = StubTransport(
            .reply(status: 400, body: refusesThinking),
            .reply(status: 200, body: recordedReply))

        let cleaned = try await refiner(transport).refine(text: "x", instruction: "rules")

        #expect(cleaned == "We should ship this on Thursday.")
        #expect(transport.requests.count == 2)
        #expect(try body(of: transport.requests[0])["think"] as? Bool == false)
        #expect(try body(of: transport.requests[1])["think"] == nil)
        #expect(try body(of: transport.requests[1])["model"] as? String == "qwen2.5-coder:7b")
    }

    @Test("asking again happens once, and only for that refusal")
    func retriesAtMostOnce() async {
        let alwaysRefuses = StubTransport(.reply(status: 400, body: refusesThinking))
        await #expect(throws: RefinementFailure.agentFailed(
            #""qwen2.5-coder:7b" does not support thinking"#)) {
            try await refiner(alwaysRefuses).refine(text: "x", instruction: "rules")
        }
        #expect(alwaysRefuses.requests.count == 2)

        let otherRefusal = StubTransport(.reply(status: 400, body: #"{"error":"model is required"}"#))
        await #expect(throws: RefinementFailure.agentFailed("model is required")) {
            try await refiner(otherRefusal).refine(text: "x", instruction: "rules")
        }
        #expect(otherRefusal.requests.count == 1)
    }

    @Test("a deadline that passes is a timeout in the caller's terms")
    func mapsTimeouts() async {
        await #expect(throws: RefinementFailure.timedOut(seconds: 20)) {
            try await refiner(StubTransport(.failure(URLError(.timedOut))))
                .refine(text: "x", instruction: "rules")
        }
    }

    @Test("a reply that is not JSON is a failure, not a cleaned transcript")
    func mapsUnreadableReplies() async {
        await #expect(throws: RefinementFailure.self) {
            try await refiner(StubTransport(.reply(status: 200, body: "<html>proxy</html>")))
                .refine(text: "x", instruction: "rules")
        }
    }

    @Test("an error in a successful reply is still an error")
    func mapsErrorsInsideReplies() async {
        await #expect(throws: RefinementFailure.agentFailed("out of memory")) {
            try await refiner(StubTransport(.reply(status: 200, body: #"{"error":"out of memory"}"#)))
                .refine(text: "x", instruction: "rules")
        }
    }

    /// The session cancels the refiner when its own deadline wins the race, and
    /// a cancelled cleanup must not come back dressed as a failure of Ollama's.
    @Test("cancelling the task cancels the request", .timeLimit(.minutes(1)))
    func honoursCancellation() async {
        let transport = StubTransport(.hang)
        let refiner = refiner(transport)
        let task = Task { try await refiner.refine(text: "x", instruction: "rules") }

        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

// MARK: -

@Suite("Ollama model catalogue")
struct OllamaModelCatalogueTests {

    private func catalogue(_ transport: StubTransport) -> OllamaModelCatalogue {
        OllamaModelCatalogue(baseURL: OllamaRefiner.defaultBaseURL, transport: transport)
    }

    @Test("nil means the recommended model rather than nothing")
    func nilIsRecommended() {
        #expect(OllamaModelCatalogue.model(named: nil) == OllamaRefiner.recommendedModel)
        #expect(OllamaModelCatalogue.model(named: "") == OllamaRefiner.recommendedModel)
        #expect(OllamaModelCatalogue.model(named: "llama3.2:3b") == "llama3.2:3b")
    }

    @Test("running is whether the version endpoint answers, quickly")
    func checksTheVersion() async throws {
        let up = StubTransport(.reply(status: 200, body: #"{"version":"0.35.1"}"#))
        #expect(await catalogue(up).isRunning())
        let request = try #require(up.last)
        #expect(request.url?.absoluteString == "http://localhost:11434/api/version")
        #expect(request.timeoutInterval <= 1)

        #expect(await catalogue(StubTransport(.failure(URLError(.cannotConnectToHost))))
            .isRunning() == false)
        #expect(await catalogue(StubTransport(.reply(status: 500, body: "")))
            .isRunning() == false)
    }

    @Test("installed models are the names the tags endpoint lists")
    func listsInstalledModels() async throws {
        let tags = """
        {"models":[{"name":"qwen2.5-coder:7b","model":"qwen2.5-coder:7b","size":4683087561},\
        {"name":"llama3.2:3b","model":"llama3.2:3b"}]}
        """
        let transport = StubTransport(.reply(status: 200, body: tags))

        #expect(await catalogue(transport).installedModels() == ["qwen2.5-coder:7b", "llama3.2:3b"])
        #expect(transport.last?.url?.absoluteString == "http://localhost:11434/api/tags")
    }

    @Test("a server that is not there has no models", arguments: [
        StubTransport.Answer.failure(URLError(.cannotConnectToHost)),
        .reply(status: 500, body: #"{"error":"boom"}"#),
        .reply(status: 200, body: "not json"),
    ])
    func hasNoModelsWhenUnreachable(_ answer: StubTransport.Answer) async {
        #expect(await catalogue(StubTransport(answer)).installedModels().isEmpty)
    }

    /// A generate request with nothing but the model is how Ollama is told to
    /// load one; a prompt would make it generate.
    @Test("preparing loads the model and keeps it as long as a cleanup would", arguments: [
        ("llama3.2:3b", "llama3.2:3b"), (nil, OllamaRefiner.recommendedModel),
    ])
    func preparesTheModel(_ chosen: String?, _ expected: String) async throws {
        let transport = StubTransport(.reply(status: 200, body: #"{"done":true,"done_reason":"load"}"#))

        await catalogue(transport).prepare(model: chosen)

        let request = try #require(transport.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://localhost:11434/api/generate")
        let json = try body(of: request)
        #expect(Set(json.keys) == ["model", "keep_alive"])
        #expect(json["model"] as? String == expected)
        #expect(json["keep_alive"] as? String == "30m")
    }

    @Test("preparing a server that is not there is not an error")
    func preparingIgnoresFailures() async {
        let transport = StubTransport(.failure(URLError(.cannotConnectToHost)))

        await catalogue(transport).prepare(model: nil)

        #expect(transport.requests.count == 1)
    }
}

// MARK: -

/// The real server, so that the recorded replies above can be shown to still
/// match it. Off unless asked for, because it loads a model of several
/// gigabytes into memory:
///
/// ```sh
/// DIKTAF_OLLAMA_TESTS=1 swift test --filter DiktafOllamaTests
/// ```
@Suite("The real server", .enabled(if: ProcessInfo.processInfo
    .environment["DIKTAF_OLLAMA_TESTS"] == "1"))
struct RealOllamaTests {

    @Test("the recommended model cleans up a sentence", .timeLimit(.minutes(2)))
    func cleansUpASentence() async throws {
        let catalogue = OllamaModelCatalogue()
        #expect(await catalogue.isRunning())
        #expect(await catalogue.installedModels().contains(OllamaRefiner.recommendedModel))
        await catalogue.prepare(model: nil)

        let refiner = OllamaRefiner(model: { nil }, timeoutSeconds: { 60 })
        let cleaned = try await refiner.refine(
            text: "so um we should uh ship this on friday i mean thursday",
            instruction: """
            Clean up this dictation transcript: remove fillers and false starts, \
            add punctuation. Reply with only the cleaned text and nothing else.
            """)

        #expect(!cleaned.isEmpty)
        #expect(cleaned.lowercased().contains("thursday"))
        #expect(!cleaned.lowercased().contains(" um "))
    }

    @Test("a model that is not there says so in the caller's terms", .timeLimit(.minutes(1)))
    func reportsAMissingModel() async {
        let refiner = OllamaRefiner(model: { "diktaf-no-such-model:1b" }, timeoutSeconds: { 10 })

        await #expect(throws: RefinementFailure.agentUnavailable(
            "Ollama'da diktaf-no-such-model:1b adlı model yok; `ollama pull diktaf-no-such-model:1b` çalıştırın")) {
            try await refiner.refine(text: "x", instruction: "rules")
        }
    }
}
