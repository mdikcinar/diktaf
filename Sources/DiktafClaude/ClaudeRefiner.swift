import DiktafCore
import Foundation

/// Cleanup, done by the `claude` CLI already signed in on this machine.
///
/// One shot with no memory and a short deadline. It never builds a prompt: the
/// instruction it is handed was built from the user's rules in the domain, which
/// is also what makes it worth caching — an instruction that is the same from one
/// dictation to the next is a prefix the service has already seen, so the first
/// cleanup of the hour pays for it and the rest do not.
public struct ClaudeRefiner: TextRefiner {
    private let executablePath: String?
    private let model: String?
    private let timeout: Duration
    private let runner: any ProcessRunner

    /// - Parameters:
    ///   - model: an alias like `haiku`, or nil for the CLI's own default.
    ///     Worth setting: the default is whichever model the user works with,
    ///     and cleaning up one sentence does not need the largest one — it is
    ///     the difference between one second and four, on every dictation.
    ///   - timeoutSeconds: past this the caller delivers the raw transcript.
    public init(
        executablePath: String? = nil,
        model: String? = "haiku",
        timeoutSeconds: Int = 20
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

    public func refine(text: String, instruction: String) async throws -> String {
        guard let executable = ClaudeExecutable.locate(explicitPath: executablePath) else {
            throw RefinementFailure.agentUnavailable(
                "the claude command was not found on this machine")
        }

        let invocation = ClaudeInvocation(
            purpose: .cleanup(instruction: instruction), model: model)

        let outcome: ProcessOutcome
        do {
            outcome = try await runner.run(
                executable: executable,
                arguments: invocation.arguments,
                standardInput: text,
                timeout: timeout
            )
        } catch ProcessRunnerFailure.timedOut(let seconds) {
            throw RefinementFailure.timedOut(seconds: seconds)
        } catch ProcessRunnerFailure.couldNotStart(let detail) {
            throw RefinementFailure.agentUnavailable(detail)
        }

        guard outcome.succeeded else {
            throw RefinementFailure.agentFailed(Self.explain(outcome))
        }

        let output: ClaudeOutput
        do {
            output = try ClaudeOutput.parse(outcome.standardOutput)
        } catch ClaudeOutputFailure.reportedError(let detail) {
            throw RefinementFailure.agentFailed(detail)
        } catch {
            throw RefinementFailure.agentFailed(String(describing: error))
        }

        guard !output.text.isEmpty else { throw RefinementFailure.emptyReply }
        return output.text
    }

    /// Whatever the CLI had to say about failing, and the exit code only when it
    /// said nothing — an error message beats a number.
    static func explain(_ outcome: ProcessOutcome) -> String {
        let stderr = outcome.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = outcome.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty { return String(stdout.prefix(400)) }
        return "the claude command exited \(outcome.exitCode)"
    }
}
