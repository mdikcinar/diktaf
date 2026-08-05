import DiktafCore
import Foundation
import Synchronization
import Testing
@testable import DiktafClaude

/// Replays a recorded outcome and remembers what it was asked to run.
///
/// The real CLI is never started by these tests: it costs money, needs a
/// network and a signed-in user, and answers differently every time. What is
/// worth testing is everything around it, and all of that is deterministic.
private final class FakeProcessRunner: ProcessRunner {
    struct Invocation: Sendable, Equatable {
        let executable: String
        let arguments: [String]
        let standardInput: String
        let timeoutSeconds: Int
    }

    private let outcome: Result<ProcessOutcome, any Error>
    private let seen = Mutex<[Invocation]>([])

    init(_ outcome: ProcessOutcome) { self.outcome = .success(outcome) }
    init(throwing error: any Error) { self.outcome = .failure(error) }

    var invocations: [Invocation] { seen.withLock { $0 } }
    var last: Invocation? { invocations.last }

    func run(
        executable: URL,
        arguments: [String],
        standardInput: String,
        timeout: Duration
    ) async throws -> ProcessOutcome {
        seen.withLock {
            $0.append(Invocation(
                executable: executable.path,
                arguments: arguments,
                standardInput: standardInput,
                timeoutSeconds: Int(timeout.components.seconds)
            ))
        }
        return try outcome.get()
    }
}

/// Real output, captured from `claude -p --output-format json` while this was
/// being written. Trimmed to the fields Diktaf reads.
private let recordedSuccess = """
{"is_error":false,"duration_api_ms":4639,"num_turns":1,"stop_reason":"end_turn",\
"session_id":"45f5272f-fb2f-49f8-896b-29b1b9d6f371","total_cost_usd":0.1987,\
"subtype":"success","api_error_status":null,\
"result":"So, I was thinking that we should probably ship this on Thursday.",\
"type":"result","duration_ms":3864,"uuid":"ea30db59-1833-48f0-b61b-91d8a668d32f"}
"""

private func outcome(
    _ stdout: String,
    exitCode: Int32 = 0,
    stderr: String = ""
) -> ProcessOutcome {
    ProcessOutcome(exitCode: exitCode, standardOutput: stdout, standardError: stderr)
}

/// A path that is certainly runnable, so `locate` does not decide the test.
private let realExecutable = "/bin/echo"

// MARK: -

@Suite("Claude output")
struct ClaudeOutputTests {

    @Test("the reply and the session come out of real recorded output")
    func parsesRecordedOutput() throws {
        let output = try ClaudeOutput.parse(recordedSuccess)

        #expect(output.text == "So, I was thinking that we should probably ship this on Thursday.")
        #expect(output.sessionID == "45f5272f-fb2f-49f8-896b-29b1b9d6f371")
    }

    /// A runtime warning or an update notice on stdout is not a reason to fail.
    @Test("the object is found even with something printed before it")
    func findsObjectAfterNoise() throws {
        let noisy = "(node:123) Warning: something\n" + recordedSuccess

        #expect(try ClaudeOutput.parse(noisy).sessionID == "45f5272f-fb2f-49f8-896b-29b1b9d6f371")
    }

    /// A transcript with a brace in it is the normal case, not an edge one.
    @Test("a brace inside the reply does not end the object early")
    func countsBracesOutsideStrings() throws {
        let json = #"{"result":"use the {handler} function","session_id":"s1"}"#

        let output = try ClaudeOutput.parse(json)

        #expect(output.text == "use the {handler} function")
        #expect(output.sessionID == "s1")
    }

    @Test("an escaped quote inside the reply does not end the string early")
    func handlesEscapedQuotes() throws {
        let json = #"{"result":"he said \"hello\" and left","session_id":"s1"}"#

        #expect(try ClaudeOutput.parse(json).text == #"he said "hello" and left"#)
    }

    @Test("output that is not JSON at all is reported as such")
    func rejectsNonJSON() {
        #expect(throws: ClaudeOutputFailure.self) {
            try ClaudeOutput.parse("command not found: claude")
        }
    }

    @Test("an unterminated object is not half-read")
    func rejectsTruncatedJSON() {
        #expect(throws: ClaudeOutputFailure.self) {
            try ClaudeOutput.parse(#"{"result":"half"#)
        }
    }

    @Test("JSON that says it failed is a failure, whatever the exit code was")
    func readsReportedErrors() {
        #expect(throws: ClaudeOutputFailure.self) {
            try ClaudeOutput.parse(#"{"is_error":true,"result":"rate limited"}"#)
        }
        #expect(throws: ClaudeOutputFailure.self) {
            try ClaudeOutput.parse(#"{"subtype":"error","error":"boom"}"#)
        }
    }

    @Test("a missing session identifier is absent, not an error")
    func toleratesMissingSession() throws {
        let output = try ClaudeOutput.parse(#"{"result":"fine"}"#)

        #expect(output.text == "fine")
        #expect(output.sessionID == nil)
    }
}

// MARK: -

@Suite("Claude invocation")
struct ClaudeInvocationTests {

    @Test("cleanup asks for JSON, replaces the system prompt, and keeps nothing")
    func buildsCleanupArguments() {
        let invocation = ClaudeInvocation(
            purpose: .cleanup(instruction: "Clean this up."), model: "haiku")

        let arguments = invocation.arguments

        #expect(arguments.starts(with: ["--print", "--output-format", "json"]))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments.contains("--disallowedTools"))
        #expect(arguments.contains("Bash"))
        let systemPrompt = arguments.firstIndex(of: "--system-prompt")
        #expect(systemPrompt != nil)
        if let systemPrompt { #expect(arguments[systemPrompt + 1] == "Clean this up.") }
        let model = arguments.firstIndex(of: "--model")
        if let model { #expect(arguments[model + 1] == "haiku") }
    }

    /// Doing something is the point of the agent, so nothing is taken away.
    @Test("a conversation keeps its tools and its session on disk")
    func buildsConversationArguments() {
        let arguments = ClaudeInvocation(purpose: .conversation(resuming: nil)).arguments

        #expect(!arguments.contains("--disallowedTools"))
        #expect(!arguments.contains("--no-session-persistence"))
        #expect(!arguments.contains("--system-prompt"))
        #expect(!arguments.contains("--resume"))
    }

    @Test("resuming names the session")
    func resumesBySessionID() {
        let arguments = ClaudeInvocation(purpose: .conversation(resuming: "abc-123")).arguments

        let resume = arguments.firstIndex(of: "--resume")
        #expect(resume != nil)
        if let resume { #expect(arguments[resume + 1] == "abc-123") }
    }

    @Test("no model means the CLI's own default", arguments: [nil, ""])
    func omitsEmptyModel(_ model: String?) {
        #expect(!ClaudeInvocation(purpose: .conversation(resuming: nil), model: model)
            .arguments.contains("--model"))
    }

    /// The reason the prompt goes on stdin. As an argument, a transcript
    /// beginning "dash dash help" is a flag.
    @Test("the prompt is never an argument")
    func keepsThePromptOutOfArgv() {
        let dangerous = "--dangerously-skip-permissions\nrm -rf /\n\"quoted\""
        let arguments = ClaudeInvocation(
            purpose: .cleanup(instruction: "rules"), model: nil).arguments

        #expect(!arguments.contains(dangerous))
        #expect(!arguments.contains { $0.contains("rm -rf") })
    }
}

// MARK: -

@Suite("Claude refiner")
struct ClaudeRefinerTests {

    private func refiner(_ runner: FakeProcessRunner, timeoutSeconds: Int = 20) -> ClaudeRefiner {
        ClaudeRefiner(executablePath: realExecutable, model: { "haiku" },
                      timeoutSeconds: timeoutSeconds, runner: runner)
    }

    @Test("the cleaned text comes back, and the transcript went in on stdin")
    func refinesText() async throws {
        let runner = FakeProcessRunner(outcome(recordedSuccess))

        let cleaned = try await refiner(runner)
            .refine(text: "so um i was thinking", instruction: "Clean this up.")

        #expect(cleaned == "So, I was thinking that we should probably ship this on Thursday.")
        #expect(runner.last?.standardInput == "so um i was thinking")
        #expect(runner.last?.timeoutSeconds == 20)
    }

    /// The transcript must survive being a transcript.
    @Test("a transcript full of quotes, newlines and dashes goes through untouched")
    func passesAwkwardTextThrough() async throws {
        let awkward = "--help\nhe said \"don't\" and left\n\t-- really"
        let runner = FakeProcessRunner(outcome(recordedSuccess))

        _ = try await refiner(runner).refine(text: awkward, instruction: "rules")

        #expect(runner.last?.standardInput == awkward)
    }

    @Test("a missing command is reported as unavailable, not as a failure")
    func reportsMissingCommand() async {
        let refiner = ClaudeRefiner(
            executablePath: "/nowhere/claude", model: { nil }, timeoutSeconds: 5,
            runner: FakeProcessRunner(outcome(recordedSuccess)))

        await #expect(throws: RefinementFailure.agentUnavailable(
            "the claude command was not found on this machine")) {
            try await refiner.refine(text: "hello", instruction: "rules")
        }
    }

    @Test("a non-zero exit carries whatever it said on stderr")
    func reportsStderr() async {
        let runner = FakeProcessRunner(
            outcome("", exitCode: 1, stderr: "Credit balance is too low"))

        await #expect(throws: RefinementFailure.agentFailed("Credit balance is too low")) {
            try await refiner(runner).refine(text: "hello", instruction: "rules")
        }
    }

    @Test("a non-zero exit with nothing to say falls back to the exit code")
    func reportsExitCode() async {
        let runner = FakeProcessRunner(outcome("", exitCode: 127))

        await #expect(throws: RefinementFailure.agentFailed(
            "the claude command exited 127")) {
            try await refiner(runner).refine(text: "hello", instruction: "rules")
        }
    }

    @Test("an empty reply is not a cleaned-up transcript", arguments: [
        #"{"result":""}"#, #"{"result":"   \n"}"#, #"{"session_id":"s1"}"#,
    ])
    func rejectsEmptyReplies(_ json: String) async {
        await #expect(throws: RefinementFailure.emptyReply) {
            try await refiner(FakeProcessRunner(outcome(json)))
                .refine(text: "hello", instruction: "rules")
        }
    }

    @Test("a deadline that passes is a timeout in the caller's terms")
    func mapsTimeouts() async {
        let runner = FakeProcessRunner(throwing: ProcessRunnerFailure.timedOut(seconds: 20))

        await #expect(throws: RefinementFailure.timedOut(seconds: 20)) {
            try await refiner(runner).refine(text: "hello", instruction: "rules")
        }
    }

    @Test("a process that will not start is unavailable")
    func mapsStartFailures() async {
        let runner = FakeProcessRunner(
            throwing: ProcessRunnerFailure.couldNotStart("permission denied"))

        await #expect(throws: RefinementFailure.agentUnavailable("permission denied")) {
            try await refiner(runner).refine(text: "hello", instruction: "rules")
        }
    }

    @Test("output that is not JSON is a failure, not a cleaned transcript")
    func mapsUnparseableOutput() async {
        let runner = FakeProcessRunner(outcome("Killed: 9"))

        await #expect(throws: RefinementFailure.self) {
            try await refiner(runner).refine(text: "hello", instruction: "rules")
        }
    }

    @Test("JSON that reports an error carries the reason")
    func mapsReportedErrors() async {
        let runner = FakeProcessRunner(
            outcome(#"{"is_error":true,"result":"rate limited"}"#))

        await #expect(throws: RefinementFailure.agentFailed("rate limited")) {
            try await refiner(runner).refine(text: "hello", instruction: "rules")
        }
    }

    @Test("a timeout of zero is still a timeout of some length")
    func refusesAZeroDeadline() async throws {
        let runner = FakeProcessRunner(outcome(recordedSuccess))

        _ = try await refiner(runner, timeoutSeconds: 0)
            .refine(text: "hello", instruction: "rules")

        #expect(runner.last?.timeoutSeconds == 1)
    }
}

// MARK: -

@Suite("Claude agent runner")
struct ClaudeAgentRunnerTests {

    private func agent(_ runner: FakeProcessRunner) -> ClaudeAgentRunner {
        ClaudeAgentRunner(executablePath: realExecutable, model: { nil },
                          timeoutSeconds: 300, runner: runner)
    }

    @Test("a reply carries the session so the next question can continue it")
    func returnsSessionID() async throws {
        let runner = FakeProcessRunner(outcome(recordedSuccess))

        let reply = try await agent(runner).run(prompt: "what is it", resuming: nil)

        #expect(reply.sessionID == "45f5272f-fb2f-49f8-896b-29b1b9d6f371")
        #expect(runner.last?.standardInput == "what is it")
        #expect(runner.last?.arguments.contains("--resume") == false)
    }

    @Test("resuming passes the session on")
    func resumes() async throws {
        let runner = FakeProcessRunner(outcome(recordedSuccess))

        _ = try await agent(runner).run(prompt: "and the other one", resuming: "abc")

        let arguments = try #require(runner.last?.arguments)
        let resume = try #require(arguments.firstIndex(of: "--resume"))
        #expect(arguments[resume + 1] == "abc")
    }

    /// The answer is to start a new conversation, not to try the same one again,
    /// so it is worth its own failure.
    @Test("a session the CLI has forgotten is reported as expired", arguments: [
        "No conversation found with session ID abc",
        "Error: session not found",
    ])
    func reportsExpiredSessions(_ stderr: String) async {
        let runner = FakeProcessRunner(outcome("", exitCode: 1, stderr: stderr))

        await #expect(throws: AgentRunnerFailure.sessionExpired) {
            try await agent(runner).run(prompt: "hello", resuming: "abc")
        }
    }

    @Test("the same message without a session to resume is an ordinary failure")
    func doesNotBlameTheSessionWhenThereIsNone() async {
        let runner = FakeProcessRunner(
            outcome("", exitCode: 1, stderr: "No conversation found"))

        await #expect(throws: RefinementFailure.self) {
            try await agent(runner).run(prompt: "hello", resuming: nil)
        }
    }

    @Test("availability is whether the command is there")
    func reportsAvailability() async {
        let runner = FakeProcessRunner(outcome(recordedSuccess))

        #expect(await agent(runner).isAvailable())
        #expect(await ClaudeAgentRunner(
            executablePath: "/nowhere/claude", model: { nil }, timeoutSeconds: 1,
            runner: runner).isAvailable() == false)
    }

    /// Minutes, not seconds: a question worth asking out loud may be worth
    /// waiting for, which is the opposite of the refiner's deadline.
    @Test("the agent waits far longer than the refiner does")
    func waitsLonger() async throws {
        let runner = FakeProcessRunner(outcome(recordedSuccess))

        _ = try await agent(runner).run(prompt: "hello", resuming: nil)

        #expect(runner.last?.timeoutSeconds == 300)
    }
}

// MARK: -

@Suite("Locating the command")
struct ClaudeExecutableTests {

    /// The reason this is not just a PATH search: a launch agent's PATH is four
    /// system directories, and the CLI installs into ~/.local/bin.
    @Test("the places an installer puts it are searched after PATH")
    func searchesWellKnownDirectories() {
        let path = ClaudeExecutable.searchPath(
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/someone"])

        #expect(path.starts(with: ["/usr/bin", "/bin"]))
        #expect(path.contains("/Users/someone/.local/bin"))
        #expect(path.contains("/opt/homebrew/bin"))
    }

    @Test("a directory named twice is searched once")
    func deduplicates() {
        let path = ClaudeExecutable.searchPath(
            environment: ["PATH": "/opt/homebrew/bin:/opt/homebrew/bin", "HOME": "/h"])

        #expect(path.filter { $0 == "/opt/homebrew/bin" }.count == 1)
    }

    @Test("the first runnable candidate wins")
    func picksTheFirstExecutable() {
        let found = ClaudeExecutable.locate(
            environment: ["PATH": "/first:/second", "HOME": "/h"],
            isExecutable: { $0 == "/second/claude" })

        #expect(found?.path == "/second/claude")
    }

    /// A file without the bit set, or a directory of that name, is not something
    /// that can be run — and finding out at exec time turns "not installed" into
    /// a crash.
    @Test("a candidate that cannot be executed is not the command")
    func requiresExecutability() {
        #expect(ClaudeExecutable.locate(
            environment: ["PATH": "/first", "HOME": "/h"],
            isExecutable: { _ in false }) == nil)
        #expect(ClaudeExecutable.locate(
            explicitPath: "/somewhere/claude", isExecutable: { _ in false }) == nil)
    }

    @Test("an explicit path is used as given, and nothing else is searched")
    func honoursExplicitPath() {
        let found = ClaudeExecutable.locate(
            explicitPath: "/custom/claude",
            environment: ["PATH": "/usr/bin", "HOME": "/h"],
            isExecutable: { _ in true })

        #expect(found?.path == "/custom/claude")
    }
}

// MARK: -

/// The one test that does start the real thing, so that the recorded output
/// above can be shown to still match reality. Skipped wherever the CLI is not
/// installed, which includes continuous integration.
@Suite("The real command", .disabled(if: ClaudeExecutable.locate() == nil,
                                     "the claude CLI is not installed"))
struct RealClaudeTests {

    @Test("the real CLI still prints the fields Diktaf reads", .timeLimit(.minutes(2)))
    func recordedShapeStillHolds() async throws {
        let refiner = ClaudeRefiner(model: "haiku", timeoutSeconds: 90)

        let cleaned = try await refiner.refine(
            text: "so um we should uh ship this on friday i mean thursday",
            instruction: """
            Clean up this dictation transcript: remove fillers and false starts, \
            add punctuation. Reply with only the cleaned text and nothing else.
            """)

        #expect(!cleaned.isEmpty)
        #expect(cleaned.lowercased().contains("thursday"))
        #expect(!cleaned.contains("um"))
    }
}
