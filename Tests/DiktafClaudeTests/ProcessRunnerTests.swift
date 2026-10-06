import Foundation
import Testing
@testable import DiktafClaude

/// The runner that does start real programs — small system ones that finish in
/// moments, never the CLI.
///
/// Worth testing against real processes because what goes wrong here is the
/// operating system's behaviour rather than this code's logic: pipes that fill
/// up, signals that are ignored, a cancelled caller left waiting on a child.
@Suite("Running a program", .timeLimit(.minutes(1)))
struct SystemProcessRunnerTests {

    private let runner = SystemProcessRunner()

    private func shell(_ script: String, timeout: Duration = .seconds(10)) async throws -> ProcessOutcome {
        try await runner.run(executable: URL(filePath: "/bin/sh"), arguments: ["-c", script],
                             standardInput: "", timeout: timeout)
    }

    /// A file the script writes its own process identifier to, so the test can
    /// ask afterwards whether that process is still there.
    private func pidFile() -> URL {
        URL(filePath: NSTemporaryDirectory()).appending(path: "diktaf-pid-\(UUID().uuidString)")
    }

    private func pid(in file: URL) async throws -> pid_t {
        for _ in 0..<100 {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the script never wrote its process identifier")
        return 0
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    @Test("what goes in on stdin comes back on stdout, with the exit code")
    func roundTripsStandardInput() async throws {
        let text = "--help\nhe said \"don't\"\n\tşimdi"

        let outcome = try await runner.run(
            executable: URL(filePath: "/bin/cat"), arguments: [],
            standardInput: text, timeout: .seconds(10))

        #expect(outcome.succeeded)
        #expect(outcome.standardOutput == text)
    }

    /// Larger than a pipe's buffer on both streams at once: a runner that reads
    /// one only after the other, or only after the exit, never gets here.
    @Test("output larger than a pipe holds does not deadlock")
    func drainsLargeOutput() async throws {
        let outcome = try await shell(
            "head -c 300000 /dev/zero | tr '\\0' a; head -c 200000 /dev/zero | tr '\\0' b >&2; exit 3")

        #expect(outcome.exitCode == 3)
        #expect(outcome.standardOutput.count == 300_000)
        #expect(outcome.standardError.count == 200_000)
    }

    /// The reason stdin is written with SIGPIPE off: a CLI that cannot start
    /// exits before reading, and the write would otherwise kill this process.
    @Test("a program that exits without reading its input is reported, not fatal")
    func survivesAClosedStandardInput() async throws {
        let outcome = try await runner.run(
            executable: URL(filePath: "/bin/sh"), arguments: ["-c", "exit 127"],
            standardInput: String(repeating: "x", count: 200_000), timeout: .seconds(10))

        #expect(outcome.exitCode == 127)
    }

    @Test("a deadline that passes stops the program and says it was a timeout")
    func timesOut() async throws {
        let file = pidFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let clock = ContinuousClock()
        let started = clock.now

        await #expect(throws: ProcessRunnerFailure.timedOut(seconds: 1)) {
            try await shell("echo $$ > '\(file.path(percentEncoded: false))'; exec /bin/sleep 30",
                            timeout: .seconds(1))
        }

        #expect(clock.now - started < .seconds(5))
        #expect(!isAlive(try await pid(in: file)))
    }

    /// The defect this pins: the dictation's own deadline cancels the cleanup,
    /// and a runner that ignored that left the session waiting on the child for
    /// as long as the child cared to run.
    @Test("cancelling the caller stops the program promptly")
    func honoursCancellation() async throws {
        let file = pidFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let script = "echo $$ > '\(file.path(percentEncoded: false))'; exec /bin/sleep 30"
        let task = Task { try await shell(script, timeout: .seconds(60)) }

        let pid = try await pid(in: file)
        #expect(isAlive(pid))

        let clock = ContinuousClock()
        let cancelled = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(clock.now - cancelled < .seconds(2))
        #expect(!isAlive(pid))
    }

    @Test("a program that ignores SIGTERM is killed after the grace period")
    func killsWhatIgnoresTerminate() async throws {
        let file = pidFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let script = "trap '' TERM; echo $$ > '\(file.path(percentEncoded: false))'; exec /bin/sleep 30"
        let task = Task { try await shell(script, timeout: .seconds(60)) }

        let pid = try await pid(in: file)
        let clock = ContinuousClock()
        let cancelled = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(clock.now - cancelled < .seconds(3))
        #expect(!isAlive(pid))
    }

    /// A grandchild that inherits stdout keeps the pipe open after the program
    /// itself has exited, and end-of-file waits for it.
    @Test("a grandchild holding the pipe open does not hold up the result")
    func doesNotWaitForGrandchildren() async throws {
        let clock = ContinuousClock()
        let started = clock.now

        let outcome = try await shell("/bin/sleep 5 & echo done")

        #expect(outcome.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "done")
        #expect(clock.now - started < .seconds(4))
    }

    @Test("a program that cannot be started is reported as such")
    func reportsStartFailures() async {
        await #expect(throws: ProcessRunnerFailure.self) {
            try await runner.run(executable: URL(filePath: "/nowhere/claude"), arguments: [],
                                 standardInput: "", timeout: .seconds(1))
        }
    }
}

// MARK: -

@Suite("The child's environment")
struct ChildEnvironmentTests {

    private let launchdParent = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": "/Users/someone",
        "USER": "someone",
        "SECRET_TOKEN": "nope",
    ]

    private func path(_ environment: [String: String]) -> [String] {
        (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    }

    /// The defect this pins: an npm-installed CLI is `#!/usr/bin/env node`, and
    /// node is beside it, not in launchd's four system directories.
    @Test("the command's own directory leads the PATH")
    func putsTheCommandsDirectoryFirst() {
        let environment = SystemProcessRunner.childEnvironment(
            for: URL(filePath: "/Users/someone/.nvm/versions/node/v22/bin/claude"),
            parent: launchdParent)

        #expect(path(environment).first == "/Users/someone/.nvm/versions/node/v22/bin")
    }

    @Test("the parent's PATH follows, then the places an installer puts things")
    func keepsTheParentsPathAndAddsWellKnownDirectories() {
        let entries = path(SystemProcessRunner.childEnvironment(
            for: URL(filePath: "/opt/homebrew/bin/claude"), parent: launchdParent))

        #expect(entries.starts(with: ["/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]))
        #expect(entries.contains("/Users/someone/.local/bin"))
        #expect(entries.contains("/usr/local/bin"))
        #expect(entries.filter { $0 == "/opt/homebrew/bin" }.count == 1)
    }

    @Test("a parent with no PATH still gets the system directories")
    func suppliesASystemPath() {
        let entries = path(SystemProcessRunner.childEnvironment(
            for: URL(filePath: "/Users/someone/.local/bin/claude"), parent: ["HOME": "/Users/someone"]))

        #expect(entries.contains("/usr/bin"))
        #expect(entries.contains("/bin"))
    }

    /// A directory with a space in it is the normal case under Application
    /// Support, and a percent-encoded one matches nothing on disk.
    @Test("the command's directory is a path, not a percent-encoded URL")
    func doesNotPercentEncode() {
        let entries = path(SystemProcessRunner.childEnvironment(
            for: URL(filePath: "/Users/someone/Application Support/bin/claude"),
            parent: launchdParent))

        #expect(entries.first == "/Users/someone/Application Support/bin")
    }

    @Test("the rest of the environment is the short list it always was")
    func keepsTheRestOfTheEnvironmentExplicit() {
        let environment = SystemProcessRunner.childEnvironment(
            for: URL(filePath: "/opt/homebrew/bin/claude"), parent: launchdParent)

        #expect(environment["HOME"] == "/Users/someone")
        #expect(environment["USER"] == "someone")
        #expect(environment["SECRET_TOKEN"] == nil)
        #expect(Set(environment.keys) == ["PATH", "HOME", "USER"])
    }
}
