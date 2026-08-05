import DiktafCore
import Foundation

/// A conversation with the local agent.
///
/// Deliberately the opposite of the refiner in every setting: tools are left
/// alone because doing something is the point, the session is written to disk
/// because the next question continues it, and the deadline is minutes rather
/// than seconds because a question worth asking out loud may be worth waiting
/// for.
public struct ClaudeAgentRunner: AgentRunner {
    private let executablePath: String?
    private let model: String?
    private let timeout: Duration
    private let runner: any ProcessRunner

    public init(
        executablePath: String? = nil,
        model: String? = nil,
        timeoutSeconds: Int = 300
    ) {
        self.init(executablePath: executablePath, model: model,
                  timeoutSeconds: timeoutSeconds, runner: SystemProcessRunner())
    }

    init(
        executablePath: String?,
        model: String?,
        timeoutSeconds: Int,
        runner: any ProcessRunner
    ) {
        self.executablePath = executablePath
        self.model = model
        self.timeout = .seconds(max(1, timeoutSeconds))
        self.runner = runner
    }

    public func isAvailable() async -> Bool {
        ClaudeExecutable.locate(explicitPath: executablePath) != nil
    }

    public func run(prompt: String, resuming sessionID: String?) async throws -> AgentReply {
        guard let executable = ClaudeExecutable.locate(explicitPath: executablePath) else {
            throw RefinementFailure.agentUnavailable(
                "the claude command was not found on this machine")
        }

        let invocation = ClaudeInvocation(
            purpose: .conversation(resuming: sessionID), model: model)

        let outcome: ProcessOutcome
        do {
            outcome = try await runner.run(
                executable: executable,
                arguments: invocation.arguments,
                standardInput: prompt,
                timeout: timeout
            )
        } catch ProcessRunnerFailure.timedOut(let seconds) {
            throw RefinementFailure.timedOut(seconds: seconds)
        } catch ProcessRunnerFailure.couldNotStart(let detail) {
            throw RefinementFailure.agentUnavailable(detail)
        }

        guard outcome.succeeded else {
            // A session the CLI no longer has is worth saying plainly, because
            // the answer is to start a new conversation rather than to try again.
            if sessionID != nil, Self.looksLikeAStaleSession(outcome) {
                throw AgentRunnerFailure.sessionExpired
            }
            throw RefinementFailure.agentFailed(ClaudeRefiner.explain(outcome))
        }

        let output = try ClaudeOutput.parse(outcome.standardOutput)
        guard !output.text.isEmpty else { throw RefinementFailure.emptyReply }
        return AgentReply(text: output.text, sessionID: output.sessionID)
    }

    private static func looksLikeAStaleSession(_ outcome: ProcessOutcome) -> Bool {
        let text = (outcome.standardError + outcome.standardOutput).lowercased()
        return text.contains("no conversation found")
            || text.contains("session not found")
            || text.contains("no such session")
    }
}

public enum AgentRunnerFailure: Error, Sendable, Equatable {
    /// The conversation being resumed is gone. Asking again without a session
    /// identifier will work.
    case sessionExpired
}
