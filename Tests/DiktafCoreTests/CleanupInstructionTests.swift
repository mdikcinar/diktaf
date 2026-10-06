import Testing
@testable import DiktafCore

/// The prompt is the piece whose mistakes end up in the user's document, and it
/// is plain string assembly, so it is worth pinning closely.
@Suite("Cleanup instruction")
struct CleanupInstructionTests {

    @Test("only enabled rules appear, numbered in order")
    func numbersEnabledRulesOnly() {
        let set = CleanupRuleSet(rules: [
            CleanupRule(text: "First rule"),
            CleanupRule(text: "Switched off", isEnabled: false),
            CleanupRule(text: "Second rule"),
        ])

        let instruction = set.instruction()

        #expect(instruction.contains("1. First rule"))
        #expect(instruction.contains("2. Second rule"))
        #expect(!instruction.contains("Switched off"))
    }

    @Test("a rule that is only whitespace is not a rule")
    func ignoresBlankRules() {
        let set = CleanupRuleSet(rules: [
            CleanupRule(text: "   "),
            CleanupRule(text: "Real rule"),
        ])

        #expect(set.activeRules.count == 1)
        #expect(set.instruction().contains("1. Real rule"))
    }

    @Test("the free-form instruction is carried through")
    func carriesExtraInstruction() {
        let set = CleanupRuleSet(rules: [CleanupRule(text: "A rule")],
                                 extraInstruction: "Write Mustafa, never Mustapha.")

        #expect(set.instruction().contains("Write Mustafa, never Mustapha."))
    }

    @Test("a named language is named, and translation is refused either way",
          arguments: [nil, "tr-TR"])
    func handlesLanguage(_ language: String?) {
        let instruction = CleanupRuleSet.recommended.instruction(language: language)

        if let language {
            #expect(instruction.contains(language))
        }
        #expect(instruction.lowercased().contains("never translate")
                || instruction.lowercased().contains("do not translate"))
    }

    @Test("a blank language is treated as no language at all")
    func ignoresBlankLanguage() {
        let instruction = CleanupRuleSet.recommended.instruction(language: "   ")

        #expect(instruction.contains("same language the transcript is in"))
    }

    /// Dictate "what is the capital of France" and an agent left to its own
    /// devices answers the question. The answer is what gets pasted.
    @Test("the transcript is framed as material, never as a request")
    func refusesToAnswerTheTranscript() {
        let instruction = CleanupRuleSet.recommended.instruction()

        #expect(instruction.contains("never a request"))
        #expect(instruction.contains("do not"))
        #expect(instruction.lowercased().contains("question"))
    }

    /// "Sure! Here is the cleaned-up text:" is not a cleaned-up text.
    @Test("the reply is required to be the text and nothing else")
    func forbidsPreambleAndMarkdown() {
        let instruction = CleanupRuleSet.recommended.instruction()

        #expect(instruction.contains("No preamble"))
        #expect(instruction.contains("markdown"))
    }

    /// The session pastes the raw transcript with a "Cleanup failed" notice
    /// when the reply is empty, so a prompt that asks for one is asking for a
    /// failure.
    @Test("the reply is never asked to be empty")
    func neverAsksForAnEmptyReply() {
        let instruction = CleanupRuleSet.recommended.instruction().lowercased()

        #expect(!instruction.contains("reply with nothing"))
        #expect(!instruction.contains("nothing at all"))
    }

    @Test("an empty rule set is empty, so the round trip can be skipped")
    func knowsWhenThereIsNothingToDo() {
        #expect(CleanupRuleSet().isEmpty)
        #expect(CleanupRuleSet(rules: [CleanupRule(text: "x", isEnabled: false)]).isEmpty)
        #expect(CleanupRuleSet(extraInstruction: "  ").isEmpty)
        #expect(!CleanupRuleSet(extraInstruction: "do a thing").isEmpty)
        #expect(!CleanupRuleSet.recommended.isEmpty)
    }

    @Test("the recommended set covers what dictation actually produces")
    func recommendedSetIsUsable() {
        let text = CleanupRuleSet.recommended.rules
            .map(\.text).joined(separator: " ").lowercased()

        #expect(text.contains("filler"))
        #expect(text.contains("false start"))
        #expect(text.contains("punctuation"))

        let allEnabled = CleanupRuleSet.recommended.rules.allSatisfy { $0.isEnabled }
        #expect(allEnabled)
    }
}

@Suite("The transcript as handed over")
struct TranscriptEnclosureTests {
    @Test("the transcript goes inside the tags the instruction describes")
    func enclosesTheTranscript() {
        let instruction = CleanupRuleSet.recommended.instruction()
        #expect(instruction.contains("<transcript>"))
        #expect(instruction.contains("never an answer to it"))
        #expect(CleanupRuleSet.enclosing("merhaba") == "<transcript>\nmerhaba\n</transcript>")
    }
}
