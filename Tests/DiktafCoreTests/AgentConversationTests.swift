import Foundation
import Synchronization
import Testing
@testable import DiktafCore

@Suite("Agent conversation")
struct AgentConversationTests {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func conversation(_ runner: FakeAgentRunner) -> AgentConversation {
        AgentConversation(runner: runner, now: { self.fixedNow },
                          isSessionExpired: { $0 is FakeSessionExpired })
    }

    @Test("the first question starts a conversation and records the reply")
    func recordsFirstTurn() async throws {
        let runner = FakeAgentRunner(.replying(text: "42", sessionID: "abc"))
        let conversation = conversation(runner)

        let turn = try await conversation.ask("what is six times seven")

        #expect(turn.outcome == .answered("42"))
        #expect(turn.reply == "42")
        #expect(turn.asked == fixedNow)
        #expect(runner.calls == [.init(prompt: "what is six times seven", resuming: nil)])
        #expect(await conversation.isOngoing)
    }

    /// Without this the second question — "and what about the other one?" —
    /// cannot be asked at all.
    @Test("the second question resumes the first")
    func resumesTheSession() async throws {
        let runner = FakeAgentRunner(.replying(text: "ok", sessionID: "abc"))
        let conversation = conversation(runner)

        try await conversation.ask("first")
        try await conversation.ask("second")

        #expect(runner.calls == [
            .init(prompt: "first", resuming: nil),
            .init(prompt: "second", resuming: "abc"),
        ])
        #expect(await conversation.turns.count == 2)
    }

    /// A runner that returns nil is saying every turn stands alone. Forgetting
    /// an id we already have would silently end a conversation that worked.
    @Test("a reply with no session id does not throw away the one we have")
    func keepsSessionWhenReplyOmitsIt() async throws {
        let runner = FakeAgentRunner(.replying(text: "ok", sessionID: nil))
        let conversation = AgentConversation(runner: runner, now: { self.fixedNow })

        // Seeded by a first runner that did offer one.
        let seeding = FakeAgentRunner(.replying(text: "ok", sessionID: "keep-me"))
        let seeded = AgentConversation(runner: seeding, now: { self.fixedNow })
        try await seeded.ask("first")
        #expect(await seeded.isOngoing)

        try await conversation.ask("only")
        #expect(await conversation.isOngoing == false)
    }

    @Test("starting over forgets the session but keeps what was said")
    func startsOver() async throws {
        let runner = FakeAgentRunner(.replying(text: "ok", sessionID: "abc"))
        let conversation = conversation(runner)
        try await conversation.ask("first")

        await conversation.startOver()
        try await conversation.ask("second")

        #expect(runner.calls.last == .init(prompt: "second", resuming: nil))
        #expect(await conversation.turns.count == 2)
    }

    @Test("clearing forgets everything")
    func clears() async throws {
        let conversation = conversation(FakeAgentRunner(.replying(text: "ok", sessionID: "abc")))
        try await conversation.ask("first")

        await conversation.clear()

        #expect(await conversation.turns.isEmpty)
        #expect(await conversation.isOngoing == false)
    }

    /// A question that vanished without trace is worse than one that visibly
    /// failed, and the user may want to ask it again.
    @Test("a failure is recorded as a turn and still thrown")
    func recordsFailures() async throws {
        let conversation = conversation(FakeAgentRunner(.failing("exit 1")))

        await #expect(throws: RefinementFailure.self) {
            try await conversation.ask("something")
        }

        let turns = await conversation.turns
        #expect(turns.count == 1)
        #expect(turns.first?.prompt == "something")
        #expect(turns.first?.reply == nil)
        if case .failed(let message) = turns.first?.outcome {
            #expect(message.contains("exit 1"))
        } else {
            Issue.record("the turn should have been recorded as failed")
        }
    }

    @Test("an empty question is not asked", arguments: ["", "   ", "\n\t"])
    func refusesEmptyPrompts(_ prompt: String) async throws {
        let runner = FakeAgentRunner(.replying(text: "ok", sessionID: "abc"))
        let conversation = conversation(runner)

        await #expect(throws: AgentConversationError.emptyPrompt) {
            try await conversation.ask(prompt)
        }
        #expect(runner.calls.isEmpty)
        #expect(await conversation.turns.isEmpty)
    }

    @Test("the question is trimmed before it is asked")
    func trimsThePrompt() async throws {
        let runner = FakeAgentRunner(.replying(text: "ok", sessionID: nil))

        try await conversation(runner).ask("  what time is it \n")

        #expect(runner.calls.first?.prompt == "what time is it")
    }

    // MARK: - Replies that arrive late

    @Test("a question is timed when it was asked, not when the answer came")
    func timesTheQuestion() async throws {
        let gate = Gate()
        let clock = SettableClock(Date(timeIntervalSince1970: 1_000))
        let runner = FakeAgentRunner(.held(gate, text: "ok", sessionID: "abc"))
        let conversation = AgentConversation(runner: runner, now: { clock.now })

        let asking = Task { try await conversation.ask("slow one") }
        try await waitUntil("the runner is asked") { runner.calls.count == 1 }
        clock.now = Date(timeIntervalSince1970: 2_000)
        await gate.open()

        let turn = try await asking.value
        #expect(turn.asked == Date(timeIntervalSince1970: 1_000))
    }

    /// The user said to forget it while the agent was still thinking. The
    /// reply arriving afterwards must not bring the conversation back.
    @Test("clearing while a question is waiting is not undone by its reply")
    func clearingDuringAQuestionSticks() async throws {
        let gate = Gate()
        let runner = FakeAgentRunner(script: [
            .replying(text: "first", sessionID: "abc"),
            .held(gate, text: "late", sessionID: "abc"),
        ])
        let conversation = conversation(runner)
        try await conversation.ask("first")

        let asking = Task { try await conversation.ask("second") }
        try await waitUntil("the runner is asked again") { runner.calls.count == 2 }
        await conversation.clear()
        await gate.open()
        _ = try await asking.value

        #expect(await conversation.turns.isEmpty)
        #expect(await conversation.isOngoing == false)
    }

    @Test("starting over while a question is waiting is not undone by its reply")
    func startingOverDuringAQuestionSticks() async throws {
        let gate = Gate()
        let runner = FakeAgentRunner(script: [
            .replying(text: "first", sessionID: "abc"),
            .held(gate, text: "late", sessionID: "abc"),
            .replying(text: "fresh", sessionID: "def"),
        ])
        let conversation = conversation(runner)
        try await conversation.ask("first")

        let asking = Task { try await conversation.ask("second") }
        try await waitUntil("the runner is asked again") { runner.calls.count == 2 }
        await conversation.startOver()
        await gate.open()
        _ = try await asking.value

        #expect(await conversation.isOngoing == false)
        #expect(await conversation.turns.map(\.prompt) == ["first"])
        try await conversation.ask("third")
        #expect(runner.calls.last == .init(prompt: "third", resuming: nil))
    }

    // MARK: - A session that has gone

    /// The conversation is gone rather than broken, so the question is asked
    /// again as a new one — and the user sees one answered question, not a
    /// failure followed by the same question answered.
    @Test("an expired session is started over and the question asked again, as one turn")
    func retriesAnExpiredSession() async throws {
        let runner = FakeAgentRunner(script: [
            .replying(text: "first", sessionID: "abc"),
            .expiring,
            .replying(text: "again", sessionID: "def"),
        ])
        let conversation = conversation(runner)
        try await conversation.ask("first")

        let turn = try await conversation.ask("second")

        #expect(turn.outcome == .answered("again"))
        #expect(runner.calls == [
            .init(prompt: "first", resuming: nil),
            .init(prompt: "second", resuming: "abc"),
            .init(prompt: "second", resuming: nil),
        ])
        #expect(await conversation.turns.map(\.outcome) == [.answered("first"), .answered("again")])
        try await conversation.ask("third")
        #expect(runner.calls.last == .init(prompt: "third", resuming: "def"))
    }

    @Test("a retry that fails too is recorded once and thrown")
    func recordsAFailedRetryOnce() async throws {
        let runner = FakeAgentRunner(script: [
            .replying(text: "first", sessionID: "abc"),
            .expiring,
            .failing("exit 1"),
        ])
        let conversation = conversation(runner)
        try await conversation.ask("first")

        await #expect(throws: RefinementFailure.agentFailed("exit 1")) {
            try await conversation.ask("second")
        }

        let turns = await conversation.turns
        #expect(turns.count == 2)
        if case .failed(let message) = turns.last?.outcome {
            #expect(message.contains("exit 1"))
        } else {
            Issue.record("the retry's failure should have been recorded")
        }
        #expect(await conversation.isOngoing == false)
    }

    @Test("a failure that is not an expired session is not retried")
    func retriesNothingElse() async throws {
        let runner = FakeAgentRunner(script: [
            .replying(text: "first", sessionID: "abc"),
            .failing("exit 1"),
        ])
        let conversation = conversation(runner)
        try await conversation.ask("first")

        await #expect(throws: RefinementFailure.self) {
            try await conversation.ask("second")
        }

        #expect(runner.calls.count == 2)
        #expect(await conversation.turns.count == 2)
        #expect(await conversation.isOngoing, "the session it was resuming is still there")
    }

    @Test("a session that expires again on the retry is not retried a second time")
    func retriesOnlyOnce() async throws {
        let runner = FakeAgentRunner(script: [
            .replying(text: "first", sessionID: "abc"),
            .expiring,
        ])
        let conversation = conversation(runner)
        try await conversation.ask("first")

        await #expect(throws: FakeSessionExpired.self) {
            try await conversation.ask("second")
        }

        #expect(runner.calls.count == 3)
        #expect(await conversation.turns.count == 2)
    }

    @Test("a first question is never retried, having no session to expire")
    func doesNotRetryWithoutASession() async throws {
        let runner = FakeAgentRunner(.expiring)
        let conversation = conversation(runner)

        await #expect(throws: FakeSessionExpired.self) {
            try await conversation.ask("first")
        }
        #expect(runner.calls.count == 1)
        #expect(await conversation.turns.count == 1)
    }
}

/// A clock a test moves by hand.
private final class SettableClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date) { current = Mutex(start) }

    var now: Date {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}
