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
    ///
    /// PATH leads with the command's own directory: an npm-installed `claude` is
    /// `#!/usr/bin/env node` with node beside it, and under launchd's PATH `env`
    /// finds none and exits 127. Then every directory `ClaudeExecutable` searched.
    static func childEnvironment(
        for executable: URL,
        parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var searched = parent
        searched["PATH"] = parent["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let ownDirectory = (executable.path(percentEncoded: false) as NSString)
            .deletingLastPathComponent

        var seen = Set<String>()
        let path = ([ownDirectory] + ClaudeExecutable.searchPath(environment: searched))
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        var environment = ["PATH": path.joined(separator: ":")]
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
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = Self.childEnvironment(for: executable)

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // Set before the launch: a program that fails at once can be gone
        // before a handler set afterwards exists, and then nobody is told.
        let termination = Termination()
        process.terminationHandler = { _ in termination.signal() }

        do {
            try process.run()
        } catch {
            throw ProcessRunnerFailure.couldNotStart(String(describing: error))
        }

        // Both pipes are drained as the data arrives, and neither waits for the
        // process. A program that fills one pipe's buffer while nobody is reading
        // it blocks forever, and waiting for it to exit first is exactly how that
        // deadlock is written.
        let standardOutput = PipeDrain(output.fileHandleForReading)
        let standardError = PipeDrain(errors.fileHandleForReading)

        Self.write(standardInput, to: input.fileHandleForWriting)

        // Recorded by whoever does the killing, rather than inferred afterwards
        // from the termination reason: a program can be killed by a signal for
        // reasons of its own, and calling that a timeout would be a lie in the
        // one message the user gets to see.
        let killedForTakingTooLong = Flag()
        let killer = Task {
            try await Task.sleep(for: timeout)
            guard process.isRunning else { return }
            killedForTakingTooLong.set()
            Self.stop(process)
        }
        defer { killer.cancel() }

        // The wait itself ignores cancellation on purpose: a cancelled caller
        // stops the program and then waits for it to be gone, so that nothing it
        // started outlives the dictation it belonged to.
        await withTaskCancellationHandler {
            await termination.wait()
        } onCancel: {
            Self.stop(process)
        }

        async let outputData = standardOutput.contents()
        async let errorData = standardError.contents()
        let outcome = ProcessOutcome(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: await outputData),
            standardError: String(decoding: await errorData)
        )

        try Task.checkCancellation()
        if killedForTakingTooLong.isSet {
            throw ProcessRunnerFailure.timedOut(seconds: timeout.wholeSeconds)
        }
        return outcome
    }

    /// The prompt arrives on stdin, so the CLI waits for end-of-file before it
    /// does anything at all. Closing is what starts the work. On a thread that
    /// may block, because a pipe holds only so much until the other side reads.
    private static func write(_ text: String, to handle: FileHandle) {
        // A program that has already exited — the npm CLI that cannot find node
        // exits at once — turns this write into SIGPIPE, which by default
        // terminates Diktaf rather than failing the write.
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = Data(text.utf8)
            if !data.isEmpty { try? handle.write(contentsOf: data) }
            try? handle.close()
        }
    }

    /// SIGTERM, and SIGKILL half a second later for whatever is still there. A
    /// CLI that spawns its own children can ignore SIGTERM for longer than
    /// matters, and whoever asked for the stop is no longer waiting for output.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(500)) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// A one-way flag two tasks can share.
private final class Flag: Sendable {
    private let value = Mutex(false)

    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

/// The moment a process ended, waited for without holding a thread.
private final class Termination: Sendable {
    private let state = Mutex<(ended: Bool, waiter: CheckedContinuation<Void, Never>?)>(
        (false, nil))

    func signal() {
        let waiter = state.withLock { state in
            state.ended = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let ended = state.withLock { state in
                if !state.ended { state.waiter = continuation }
                return state.ended
            }
            if ended { continuation.resume() }
        }
    }
}

/// Everything a pipe delivers, collected as it arrives rather than by a blocking
/// read: end-of-file waits for every holder of the other end, grandchildren
/// included, so once the program has exited `contents` waits only briefly.
private final class PipeDrain: Sendable {
    private struct State {
        var data = Data()
        var ended = false
        var waiter: CheckedContinuation<Data, Never>?
    }

    private let handle: FileHandle
    private let state = Mutex(State())

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                self?.end()
            } else {
                self?.state.withLock { $0.data.append(chunk) }
            }
        }
    }

    /// What arrived, once end-of-file does or `grace` has passed without it.
    func contents(grace: Duration = .seconds(1)) async -> Data {
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: grace)) != nil else { return }
            self?.end()
        }
        defer { timer.cancel() }

        return await withCheckedContinuation { continuation in
            let ready: Data? = state.withLock { state in
                if state.ended { return state.data }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    private func end() {
        handle.readabilityHandler = nil
        let (waiter, data) = state.withLock { state in
            state.ended = true
            defer { state.waiter = nil }
            return (state.waiter, state.data)
        }
        waiter?.resume(returning: data)
    }
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
