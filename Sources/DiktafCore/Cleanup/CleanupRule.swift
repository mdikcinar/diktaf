import Foundation

/// One thing the user wants done to every transcript, in their own words.
///
/// A sentence rather than a setting, because the thing doing the work reads
/// sentences. That also means a rule the user invents is worth exactly as much
/// as one shipped here, which is the point.
public struct CleanupRule: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var text: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), text: String, isEnabled: Bool = true) {
        self.id = id
        self.text = text
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, isEnabled
    }

    /// Only the sentence is required. A rule written into the file by hand has
    /// no identifier, and a rule somebody bothered to write is meant to be on.
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        text = try box.decode(String.self, forKey: .text)
        id = (try? box.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        isEnabled = (try? box.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
    }
}

/// The rules, plus room for anything they do not cover.
public struct CleanupRuleSet: Codable, Sendable, Equatable {
    public var rules: [CleanupRule]

    /// Free-form, appended after the rules. For the things a person only
    /// discovers they need once they have used this for a week — a name it keeps
    /// mishearing, a house style, a language to translate into.
    public var extraInstruction: String?

    public init(rules: [CleanupRule] = [], extraInstruction: String? = nil) {
        self.rules = rules
        self.extraInstruction = extraInstruction
    }

    private enum CodingKeys: String, CodingKey {
        case rules, extraInstruction
    }

    /// A rule that cannot be read is dropped and the others kept. Rules that
    /// are not a list at all still fail, so that `Settings` falls back to the
    /// recommended set rather than to none.
    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        rules = try box.decodeIfPresent([Forgiving<CleanupRule>].self, forKey: .rules)?
            .compactMap(\.value) ?? []
        extraInstruction = try? box.decodeIfPresent(String.self, forKey: .extraInstruction)
    }

    /// What a transcript needs done to it whatever else the user adds.
    ///
    /// Every one of these is here because dictation produces it and typing does
    /// not: the *uh*s, the sentence started twice, the missing punctuation a
    /// recogniser cannot infer. The last two are not about the text but about
    /// the reply — an agent that explains itself, or wraps the answer in
    /// backticks, has written that into the user's document.
    public static let recommended = CleanupRuleSet(rules: [
        CleanupRule(text: "Remove filler words and hesitations: uh, um, er, you know, I mean, like when it is not doing any work."),
        CleanupRule(text: "Remove false starts and repeated words, keeping the version the speaker settled on."),
        CleanupRule(text: "Add the punctuation and capitalisation the speaker clearly intended, and break the text into paragraphs where they paused."),
        CleanupRule(text: "Fix words the recogniser plainly misheard where the intended word is obvious from the context."),
        CleanupRule(text: "Keep the speaker's own wording, tone and language. Do not translate, summarise, expand, or make it more formal."),
        CleanupRule(text: "Preserve the meaning exactly. Never add a fact, an opinion, or a sentence the speaker did not say."),
    ])

    /// The rules that are actually in force.
    public var activeRules: [CleanupRule] {
        rules.filter { $0.isEnabled && !$0.text.trimmed.isEmpty }
    }

    /// Whether there is anything to do at all. An empty rule set means the
    /// transcript would come back unchanged, so the caller can skip the round
    /// trip entirely.
    public var isEmpty: Bool {
        activeRules.isEmpty && (extraInstruction?.trimmed.isEmpty ?? true)
    }
}
