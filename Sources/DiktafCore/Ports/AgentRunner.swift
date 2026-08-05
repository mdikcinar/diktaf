import Foundation

/// A local coding agent, asked one thing at a time.
///
/// Separate from `TextRefiner` although the same program answers both today,
/// because they are asked for different things and fail differently. Cleaning
/// up is one shot with no memory and a short deadline; the agent is a
/// conversation that may take minutes and is worth resuming.
public protocol AgentRunner: Sendable {
    /// Whether the agent can be reached at all, checked before it is offered.
    func isAvailable() async -> Bool

    /// One turn. Passing a `sessionID` continues that conversation; passing nil
    /// starts a new one.
    func run(prompt: String, resuming sessionID: String?) async throws -> AgentReply
}

/// What one turn produced, and the handle for continuing it.
public struct AgentReply: Sendable, Equatable {
    /// What the agent said, as text meant for a person to read.
    public let text: String

    /// The conversation this turn belonged to, to be passed back next time.
    /// Nil when the agent does not offer one, in which case every turn stands
    /// alone and the domain says so rather than pretending otherwise.
    public let sessionID: String?

    public init(text: String, sessionID: String? = nil) {
        self.text = text
        self.sessionID = sessionID
    }
}
