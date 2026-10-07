import Foundation

/// Turns a raw transcript into the text a person meant to write.
///
/// The port takes a finished instruction rather than the settings it came from, so
/// that building the instruction stays here, in the domain, where it can be
/// tested without starting a process — and so that the adapter has exactly one
/// job: hand two strings to an agent and return what comes back.
public protocol TextRefiner: Sendable {
    func refine(text: String, instruction: String) async throws -> String
}

/// Why refinement could not happen. Every one of these is recoverable by
/// pasting the raw transcript instead, which is what the session does: a
/// dictation that reaches the clipboard uncleaned is a far better outcome than
/// one that disappears.
public enum RefinementFailure: Error, Sendable, Equatable {
    /// The local agent is not installed, or not on the PATH.
    case agentUnavailable(String)
    /// It ran and failed. The text is its own account of why.
    case agentFailed(String)
    /// It ran and said nothing, which cannot be the cleaned transcript.
    case emptyReply
    /// It was still going when the deadline passed.
    case timedOut(seconds: Int)
}
