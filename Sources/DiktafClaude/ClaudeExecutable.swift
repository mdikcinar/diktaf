import Foundation

/// Finding the `claude` command.
///
/// This looks over-engineered until Diktaf is started by launchd, which is how
/// it starts at login. A launch agent's PATH is `/usr/bin:/bin:/usr/sbin:/sbin`
/// and nothing else, so the CLI — which installs into `~/.local/bin` — is not on
/// it. Searching PATH alone would mean cleanup worked when Diktaf was started
/// from a terminal and silently did not the rest of the time.
public struct ClaudeExecutable: Sendable {
    /// Where to look when PATH does not have it, in the order the installers use.
    static func wellKnownDirectories(home: String) -> [String] {
        [
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "\(home)/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
    }

    /// Every directory worth looking in, PATH first.
    static func searchPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let fromPath = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        let home = environment["HOME"] ?? NSHomeDirectory()

        var seen = Set<String>()
        return (fromPath + wellKnownDirectories(home: home)).filter { seen.insert($0).inserted }
    }

    /// The command, or nil if it is not installed.
    ///
    /// `isExecutableFile` rather than `fileExists`: a directory called `claude`,
    /// or a file without the bit set, is not something that can be run, and
    /// finding out at exec time turns a clear "not installed" into a crash
    /// report.
    public static func locate(
        explicitPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        if let explicitPath {
            return isExecutable(explicitPath) ? URL(filePath: explicitPath) : nil
        }
        for directory in searchPath(environment: environment) {
            let candidate = "\(directory)/claude"
            if isExecutable(candidate) { return URL(filePath: candidate) }
        }
        return nil
    }
}
