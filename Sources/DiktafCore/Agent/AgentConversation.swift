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
    private let isSessionExpired: @Sendable (any Error) -> Bool

    private var sessionID: String?
    private var recorded: [AgentTurn] = []

    /// Bumped by `startOver` and `clear`. A reply already on its way belongs to
    /// the conversation the user has left, so it neither brings the session
    /// back nor lands in the history.
    private var epoch = 0

    /// `now` is injected so the tests can pin the timestamps rather than
    /// asserting around them.
    ///
    /// `isSessionExpired` says whether an error from the runner means the
    /// session being resumed is gone. Passed in because the error that says so
    /// is the adapter's, and this cannot see it.
    public init(
        runner: any AgentRunner,
        now: @escaping @Sendable () -> Date = { Date() },
        isSessionExpired: @escaping @Sendable (any Error) -> Bool = { _ in false }
    ) {
        self.runner = runner
        self.now = now
        self.isSessionExpired = isSessionExpired
    }

    public var turns: [AgentTurn] { recorded }

    /// Whether there is a conversation to continue, as against a first question.
    public var isOngoing: Bool { sessionID != nil }

    /// Asks one question, continuing the conversation if there is one.
    ///
    /// Throws what the runner threw, having recorded the failure first: the
    /// caller decides how to show it, but the transcript of what was asked is
    /// not lost either way. A session that turns out to have expired is
    /// started over and the question asked once more, and only how that second
    /// attempt went is recorded.
    @discardableResult
    public func ask(_ prompt: String) async throws -> AgentTurn {
        let question = prompt.trimmed
        guard !question.isEmpty else { throw AgentConversationError.emptyPrompt }

        let asked = now()
        let epoch = self.epoch

        do {
            let reply = try await reply(to: question, from: epoch)
            let turn = AgentTurn(prompt: question, asked: asked,
                                 outcome: .answered(reply.text))
            guard epoch == self.epoch else { return turn }
            // Only replaced when the runner offers one: a runner that returns
            // nil is saying every turn stands alone, and forgetting an id we
            // already have would silently end a conversation that was working.
            if let id = reply.sessionID { sessionID = id }
            recorded.append(turn)
            return turn
        } catch {
            let turn = AgentTurn(prompt: question, asked: asked,
                                 outcome: .failed(String(describing: error)))
            if epoch == self.epoch { recorded.append(turn) }
            throw error
        }
    }

    private func reply(to question: String, from epoch: Int) async throws -> AgentReply {
        let resuming = sessionID
        do {
            return try await runner.run(prompt: question, resuming: resuming)
        } catch where resuming != nil && isSessionExpired(error) {
            // The conversation is gone rather than broken, so the question is
            // worth asking again as a new one instead of reporting a failure the
            // user can do nothing about.
            if epoch == self.epoch { sessionID = nil }
            return try await runner.run(prompt: question, resuming: nil)
        }
    }

    /// Forgets the session so the next question starts fresh. The turns already
    /// recorded stay, because they are what the user is looking at.
    public func startOver() {
        epoch += 1
        sessionID = nil
    }

    /// Forgets everything, session and history alike.
    public func clear() {
        epoch += 1
        sessionID = nil
        recorded.removeAll()
    }
}

public enum AgentConversationError: Error, Sendable, Equatable {
    case emptyPrompt
}
