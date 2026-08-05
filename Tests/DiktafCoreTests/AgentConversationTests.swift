import Foundation
import Testing
@testable import DiktafCore

@Suite("Agent conversation")
struct AgentConversationTests {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func conversation(_ runner: FakeAgentRunner) -> AgentConversation {
        AgentConversation(runner: runner, now: { self.fixedNow })
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
}
