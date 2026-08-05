import Foundation
import Synchronization

/// One run of a program: what it printed, and how it ended.
public struct ProcessOutcome: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// Running a program, behind a protocol so the tests never start one.
///
/// Everything above this line — the argument list, the parsing, the mapping of
/// exit codes onto failures — is then testable offline and deterministically,
/// which is most of what can go wrong.
protocol ProcessRunner: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        standardInput: String,
        timeout: Duration
    ) async throws -> ProcessOutcome
}

enum ProcessRunnerFailure: Error, Sendable, Equatable {
    case timedOut(seconds: Int)
    case couldNotStart(String)
}

/// The real one.
struct SystemProcessRunner: ProcessRunner {
    /// The environment handed to the child.
    ///
    /// Explicit rather than inherited: an application started by launchd has
    /// almost nothing in its environment, and one started from a terminal has
    /// everything the user's shell profile put there — so inheriting means the
    /// program behaves differently depending on how Diktaf itself was started.
    ///
    /// HOME is not optional. It is where the CLI keeps the credentials of the
    /// signed-in user, and without it every run fails as though nobody had ever
    /// logged in.
    private static func childEnvironment() -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "PATH": parent["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SHELL"] {
            if let value = parent[key] { environment[key] = value }
        }
        return environment
    }

    func run(
        executable: URL,
        arguments: [String],
        standardInput: String,
        timeout: Duration
    ) async throws -> ProcessOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = Self.childEnvironment()

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw ProcessRunnerFailure.couldNotStart(String(describing: error))
        }

        // Both pipes are drained on tasks of their own, and neither wait for the
        // process. A program that fills one pipe's buffer while nobody is reading
        // it blocks forever, and waiting for it to exit first is exactly how that
        // deadlock is written.
        let outputTask = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        let errorTask = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }

        if let data = standardInput.data(using: .utf8), !data.isEmpty {
            try? input.fileHandleForWriting.write(contentsOf: data)
        }
        // The prompt arrives on stdin, so the CLI waits for end-of-file before it
        // does anything at all. Closing is what starts the work.
        try? input.fileHandleForWriting.close()

        // Recorded by whoever does the killing, rather than inferred afterwards
        // from the termination reason: a program can be killed by a signal for
        // reasons of its own, and calling that a timeout would be a lie in the
        // one message the user gets to see.
        let killedForTakingTooLong = Flag()
        let killer = Task {
            try await Task.sleep(for: timeout)
            guard process.isRunning else { return }
            killedForTakingTooLong.set()
            process.terminate()
            // A CLI that spawns its own children can ignore SIGTERM for longer
            // than matters, and the deadline has already passed.
            try? await Task.sleep(for: .milliseconds(500))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        defer { killer.cancel() }

        // waitUntilExit blocks its thread, so it gets one of its own. The pipes
        // are already being drained, which is what keeps this from deadlocking.
        await Task.detached { process.waitUntilExit() }.value

        let standardOutput = String(decoding: await outputTask.value)
        let standardError = String(decoding: await errorTask.value)

        if killedForTakingTooLong.isSet {
            throw ProcessRunnerFailure.timedOut(seconds: timeout.wholeSeconds)
        }

        return ProcessOutcome(
            exitCode: process.terminationStatus,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }
}

/// A one-way flag two tasks can share.
private final class Flag: Sendable {
    private let value = Mutex(false)

    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

extension String {
    /// Output from another program is not guaranteed to be valid UTF-8, and the
    /// bytes that are readable are worth more than an error.
    init(decoding data: Data) {
        self = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }
}

extension Duration {
    var wholeSeconds: Int { Int(components.seconds) }
}
