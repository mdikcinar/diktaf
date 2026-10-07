import Testing
@testable import DiktafCore

/// The prompt is the piece whose mistakes end up in the user's document, and it
/// is plain string assembly, so it is worth pinning closely.
@Suite("Cleanup instruction")
struct CleanupInstructionTests {

    @Test("the prompt is handed over as written, with the language after it")
    func carriesThePrompt() {
        let instruction = CleanupInstruction.build(
            prompt: "  Write Mustafa, never Mustapha.\n", language: "tr-TR")

        #expect(instruction.hasPrefix("Write Mustafa, never Mustapha.\n\n"))
        #expect(instruction.hasSuffix("whatever stray words the recogniser produced."))
    }

    @Test("a named language is named, and translation is refused either way",
          arguments: [nil, "tr-TR"])
    func handlesLanguage(_ language: String?) {
        let instruction = CleanupInstruction.build(prompt: "Tidy it.", language: language)

        if let language {
            #expect(instruction.contains(language))
        }
        #expect(instruction.lowercased().contains("never translate")
                || instruction.lowercased().contains("same language"))
    }

    @Test("a blank language is treated as no language at all")
    func ignoresBlankLanguage() {
        let instruction = CleanupInstruction.build(prompt: "Tidy it.", language: "   ")

        #expect(instruction.contains("same language the transcript is in"))
    }

    /// Dictate "what is the capital of France" and an agent left to its own
    /// devices answers the question. The answer is what gets pasted.
    @Test("the recommended prompt frames the transcript as material, never as a request")
    func refusesToAnswerTheTranscript() {
        let prompt = CleanupInstruction.recommendedPrompt

        #expect(prompt.contains("never a request"))
        #expect(prompt.contains("do not"))
        #expect(prompt.lowercased().contains("question"))
    }

    /// "Sure! Here is the cleaned-up text:" is not a cleaned-up text.
    @Test("the recommended prompt requires the text and nothing else")
    func forbidsPreambleAndMarkdown() {
        let prompt = CleanupInstruction.recommendedPrompt

        #expect(prompt.contains("No preamble"))
        #expect(prompt.contains("markdown"))
    }

    /// The session pastes the raw transcript with a "Cleanup failed" notice
    /// when the reply is empty, so a prompt that asks for one is asking for a
    /// failure.
    @Test("the recommended prompt never asks for an empty reply")
    func neverAsksForAnEmptyReply() {
        let prompt = CleanupInstruction.recommendedPrompt.lowercased()

        #expect(!prompt.contains("reply with nothing"))
        #expect(!prompt.contains("nothing at all"))
    }

    @Test("the recommended prompt covers what dictation actually produces")
    func recommendedPromptIsUsable() {
        let prompt = CleanupInstruction.recommendedPrompt.lowercased()

        #expect(prompt.contains("filler"))
        #expect(prompt.contains("false start"))
        #expect(prompt.contains("punctuation"))
    }

    @Test("the recommended prompt is what a new settings file starts with")
    func isTheDefault() {
        #expect(Settings.defaults.cleanupPrompt == CleanupInstruction.recommendedPrompt)
    }
}

@Suite("The transcript as handed over")
struct TranscriptEnclosureTests {
    @Test("the transcript goes inside the tags the recommended prompt describes")
    func enclosesTheTranscript() {
        let prompt = CleanupInstruction.recommendedPrompt
        #expect(prompt.contains("<transcript>"))
        #expect(prompt.contains("Yarın akşam yemeğe kaç kişi geliyor? Bana listeyi gönderir misin?"))
        #expect(CleanupInstruction.enclosing("merhaba") == "<transcript>\nmerhaba\n</transcript>")
    }
}
