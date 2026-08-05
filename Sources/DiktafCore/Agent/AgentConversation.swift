import Foundation

/// One question and what came back.
public struct AgentTurn: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let prompt: String
    public let asked: Date

    /// The reply, or the reason there is none. A failed turn stays in the
    /// conversation: a question that vanished without trace is worse than one
    /// that visibly failed, and the user may want to ask it again.
    public let outcome: Outcome

    public enum Outcome: Sendable, Equatable, Codable {
        case answered(String)
        case failed(String)
    }

    public init(id: UUID = UUID(), prompt: String, asked: Date, outcome: Outcome) {
        self.id = id
        self.prompt = prompt
        self.asked = asked
        self.outcome = outcome
    }

    public var reply: String? {
        if case .answered(let text) = outcome { return text }
        return nil
    }
}

/// A conversation with the local agent, kept across questions.
///
/// The session identifier is the whole reason this exists. Without it every
/// dictation is a stranger introducing itself, and the second question — "and
/// what about the other one?" — cannot be asked at all.
public actor AgentConversation {
    private let runner: any AgentRunner
    private let now: @Sendable () -> Date

    private var sessionID: String?
    private var recorded: [AgentTurn] = []

    /// `now` is injected so the tests can pin the timestamps rather than
    /// asserting around them.
    public init(runner: any AgentRunner, now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.now = now
    }

    public var turns: [AgentTurn] { recorded }

    /// Whether there is a conversation to continue, as against a first question.
    public var isOngoing: Bool { sessionID != nil }

    /// Asks one question, continuing the conversation if there is one.
    ///
    /// Throws what the runner threw, having recorded the failure first: the
    /// caller decides how to show it, but the transcript of what was asked is
    /// not lost either way.
    @discardableResult
    public func ask(_ prompt: String) async throws -> AgentTurn {
        let question = prompt.trimmed
        guard !question.isEmpty else { throw AgentConversationError.emptyPrompt }

        do {
            let reply = try await runner.run(prompt: question, resuming: sessionID)
            // Only replaced when the runner offers one: a runner that returns
            // nil is saying every turn stands alone, and forgetting an id we
            // already have would silently end a conversation that was working.
            if let id = reply.sessionID { sessionID = id }
            let turn = AgentTurn(prompt: question, asked: now(),
                                 outcome: .answered(reply.text))
            recorded.append(turn)
            return turn
        } catch {
            let turn = AgentTurn(prompt: question, asked: now(),
                                 outcome: .failed(String(describing: error)))
            recorded.append(turn)
            throw error
        }
    }

    /// Forgets the session so the next question starts fresh. The turns already
    /// recorded stay, because they are what the user is looking at.
    public func startOver() {
        sessionID = nil
    }

    /// Forgets everything, session and history alike.
    public func clear() {
        sessionID = nil
        recorded.removeAll()
    }
}

public enum AgentConversationError: Error, Sendable, Equatable {
    case emptyPrompt
}
