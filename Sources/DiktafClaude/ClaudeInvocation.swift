import Foundation

/// The argument list for one run of the CLI.
///
/// A value rather than a string built at the call site, so that the exact argv
/// is something a test can assert on. The prompt is never in it: it goes on
/// stdin, which is the only way a transcript containing newlines, quotes or a
/// leading dash cannot be mistaken for a flag.
struct ClaudeInvocation: Sendable, Equatable {
    /// What the CLI is being asked to do, since the two jobs want different
    /// flags and different deadlines.
    enum Purpose: Sendable, Equatable {
        /// One shot, no memory, no tools, nothing kept.
        case cleanup(instruction: String)
        /// A turn of a conversation, resumed if there is one to resume.
        case conversation(resuming: String?)
    }

    var purpose: Purpose
    var model: String?

    var arguments: [String] {
        // --print with JSON: the text is in `result` and the session identifier
        // beside it, which is the only way to continue a conversation later.
        var arguments = ["--print", "--output-format", "json"]

        if let model, !model.isEmpty {
            arguments += ["--model", model]
        }

        // Nothing this machine has configured for other purposes should change
        // what a dictation turns into: no MCP servers to start, no project
        // settings to read.
        arguments += ["--strict-mcp-config"]

        switch purpose {
        case .cleanup(let instruction):
            arguments += [
                // Replaces the default system prompt rather than adding to it:
                // the rules are the whole of the job here.
                "--system-prompt", instruction,
                // Nothing to resume, so nothing worth writing to disk. It also
                // keeps a user's session list from filling up with one entry per
                // sentence they ever dictated.
                "--no-session-persistence",
                // Cleaning up text needs no tools, and a cleanup that reads a
                // file or runs a command is a cleanup that has misunderstood
                // its transcript.
                "--disallowedTools",
            ] + Self.everyTool
        case .conversation(let sessionID):
            if let sessionID, !sessionID.isEmpty {
                arguments += ["--resume", sessionID]
            }
        }

        return arguments
    }

    /// Named individually because there is no flag for "none of them", and a
    /// name that no longer exists is ignored rather than refused — so this
    /// staying slightly out of date costs nothing.
    static let everyTool = [
        "Bash", "Edit", "Write", "Read", "Glob", "Grep", "WebFetch", "WebSearch",
        "NotebookEdit", "TodoWrite", "Task", "Agent",
    ]
}
